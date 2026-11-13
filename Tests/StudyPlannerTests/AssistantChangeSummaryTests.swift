import XCTest
import SwiftUI
import AppKit
import StudyCore
@testable import StudyPlanner

final class AssistantChangeSummaryTests: XCTestCase {
    private func movedTask() throws -> AssistantChange {
        let base = AssistantSimulation.snapshot()
        var state = base.state
        state.courses[0].deadline = try base.date("2026-09-20")
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        let snapshot = AssistantSnapshot(state: state, now: base.now, calendar: base.calendar)
        return try XCTUnwrap(AssistantActions.execute(name: "preview_move_task", input: [
            "task": try XCTUnwrap(state.tasks.first?.id.uuidString), "target_date": "2026-09-15", "start_time": ""
        ], snapshot: snapshot, id: "E1").1)
    }

    func testMoveCountsAndDailyChartUseTheSamePreview() throws {
        let change = try movedTask(), summary = change.presentation
        XCTAssertEqual(summary.added, 0); XCTAssertEqual(summary.modified, 1); XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(summary.counts[2].modified, 1)
        XCTAssertEqual(summary.unchangedCategories, "课程、事项、学习记录")
        let chart = try XCTUnwrap(summary.workload)
        XCTAssertEqual(chart.labels, ["9/14", "9/15", "9/16", "9/17", "9/18", "9/19", "9/20"])
        XCTAssertEqual(chart.series[0].values, [60, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(chart.series[1].values, [0, 60, 0, 0, 0, 0, 0])
        XCTAssertEqual(change.details.filter { $0.hasPrefix("修改学习任务") }.count, 1)
        XCTAssertNoThrow(try summary.validate())
    }

    func testCourseDeletionCountsCascadeAndRenameOmitsUnchangedChart() throws {
        let snapshot = AssistantSimulation.snapshot()
        let deletion = try XCTUnwrap(AssistantActions.execute(name: "preview_delete_course", input: [
            "course": AssistantSimulation.courseID.uuidString
        ], snapshot: snapshot, id: "E1").1)
        XCTAssertEqual(deletion.presentation.counts[0].removed, 1)
        XCTAssertEqual(deletion.presentation.counts[2].removed, snapshot.state.tasks.count)
        XCTAssertEqual(deletion.presentation.workload?.series[1].values, Array(repeating: 0, count: 7))
        let rename = try XCTUnwrap(AssistantActions.execute(name: "preview_edit_course", input: [
            "course": AssistantSimulation.courseID.uuidString, "field": "name", "value": "合成新名称"
        ], snapshot: snapshot, id: "E2").1)
        XCTAssertNil(rename.presentation.workload)
        XCTAssertEqual(rename.presentation.modified, 1)
    }

    func testChartUsesLocalStartDayAndDoesNotSubstituteFloatingWindowOrCompletion() throws {
        let base = AssistantSimulation.snapshot()
        let midnight = try base.date("2026-09-15")
        var state = base.state
        let crossing = ScheduledTask(courseID: AssistantSimulation.courseID, start: midnight.addingTimeInterval(-1800), durationMinutes: 60, status: .completed)
        var floating = ScheduledTask(courseID: AssistantSimulation.courseID, start: midnight, durationMinutes: 30)
        floating.floatingWindowStart = midnight; floating.floatingWindowEnd = midnight.addingTimeInterval(4 * 3600)
        state.tasks = [crossing, floating]
        var after = state
        after.tasks[1].start = try base.date("2026-09-16")
        let chart = try XCTUnwrap(AssistantChangeSummary.workload(before: state, after: after, snapshot: base))
        XCTAssertEqual(chart.series[0].values, [60, 30, 0, 0, 0, 0, 0])
        XCTAssertEqual(chart.series[1].values, [60, 0, 30, 0, 0, 0, 0])
    }

    func testSummaryHistoryCopyAndContextRemainReadableWithoutPlannerState() throws {
        let summary = try movedTask().presentation
        let entry = AssistantChatEntry(role: "助手", text: "已生成预览，尚未保存。", status: "完成", changeSummary: summary)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantHistoryStore(url: root.appendingPathComponent("history.json"))
        try store.save(.init(conversations: [.init(entries: [entry])]))
        let loaded = try XCTUnwrap(store.load().conversations.first?.entries.first)
        XCTAssertEqual(loaded.changeSummary, summary)
        XCTAssertTrue(loaded.copyText.contains("9/15\t0\t60"))
        let messages = try AssistantConversationContext.messages(history: [loaded], memories: [], current: "继续")
        XCTAssertTrue(messages[0].content.contains("历史方案快照（不是当前课表）"))
        XCTAssertTrue(messages[0].content.contains(summary.title))
        let bytes = try assistantJSON(entry), encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(encoded.contains(AssistantSimulation.courseID.uuidString))
        XCTAssertFalse(encoded.contains("snapshotID")); XCTAssertFalse(encoded.contains("fixedEvents"))
        let legacy = AssistantChatEntry(role: "助手", text: "旧回复", status: "完成")
        XCTAssertNil(try JSONDecoder().decode(AssistantChatEntry.self, from: assistantJSON(legacy)).changeSummary)
    }

    @MainActor func testFocusResponsePersistsCardWithoutRepeatingStatisticsOrExtraRequest() async throws {
        let snapshot = AssistantSimulation.snapshot()
        let transport = AssistantMockTransport(script: [("preview_focus_today", ["course": AssistantSimulation.courseID.uuidString])])
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot }, transportFactory: { transport })
        session.configuration = AssistantSimulation.configuration(); session.question = "今天集中学习合成课程"; session.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while session.busy, ContinuousClock.now < deadline {
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.busy); XCTAssertNil(session.message)
        let entry = try XCTUnwrap(session.entries.last)
        XCTAssertNotNil(entry.changeSummary)
        XCTAssertEqual(entry.changeSummary, session.pendingChange?.presentation)
        XCTAssertFalse(entry.text.contains("新增")); XCTAssertTrue(entry.text.contains("尚未保存"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].body.contains("不重复工具summary"))
        session.dismissChange(try XCTUnwrap(session.pendingChange?.id))
        XCTAssertNil(session.pendingChange)
        XCTAssertEqual(session.entries.first { $0.id == entry.id }?.changeSummary, entry.changeSummary)
    }

    @MainActor func testCardsRenderAtNarrowAndWideWidthsInBothAppearances() throws {
        _ = NSApplication.shared
        let snapshot = AssistantSimulation.snapshot()
        let summary = try XCTUnwrap(AssistantActions.execute(name: "preview_focus_today", input: [
            "course": AssistantSimulation.courseID.uuidString
        ], snapshot: snapshot, id: "E1").1).presentation
        for width in [330.0, 680.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = AssistantChangeSummaryView(summary: summary).padding(12).frame(width: width)
                    .background(scheme == .dark ? Color(white: 0.08) : .white).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertGreaterThan(host.fittingSize.height, 500)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["STUDYPLANNER_CHANGE_RENDER_DIR"] {
                    let path = URL(fileURLWithPath: directory).appendingPathComponent("summary-\(Int(width))-\(scheme == .dark ? "dark" : "light").png")
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
                }
            }
        }
    }
}
