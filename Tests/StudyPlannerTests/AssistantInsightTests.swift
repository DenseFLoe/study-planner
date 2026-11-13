import XCTest
import SwiftUI
import AppKit
import StudyCore
@testable import StudyPlanner

final class AssistantInsightTests: XCTestCase {
    private func query(_ name: String, _ input: [String: String], snapshot: AssistantSnapshot = AssistantChartSimulation.snapshot()) throws -> AssistantInsightQuery {
        .init(name: name, input: input, evidence: try AssistantTools.query(name: name, input: input, snapshot: snapshot, id: "E1", previous: []))
    }
    private func fixtures() throws -> [AssistantInsightQuery] {
        try AssistantInsightSimulation.script.map { try query($0.0, $0.1) }
    }
    func testCardsUseQueriedFactsAndDeduplicateCoursePages() throws {
        var queries = try fixtures()
        queries.append(try query("inspect_course", ["course": AssistantSimulation.courseID.uuidString, "offset": "0"]))
        let cards = AssistantInsights.build(queries, answer: "简短解释")
        XCTAssertEqual(cards.map(\.kind), [.statistics, .course, .schedule, .conflicts, .rules])
        XCTAssertEqual(cards[0].metrics.map(\.value), [405, 510, 0])
        XCTAssertEqual(cards[0].chart?.labels, (14...20).map { "2026-09-\($0)" })
        XCTAssertEqual(cards[0].chart?.axisLabel("2026-09-14"), "9/14")
        XCTAssertEqual(cards[0].chart?.axisLabel("1 · 2026-09-14"), "窗口1")
        XCTAssertEqual(cards[0].chart?.axisLabel("课程甲"), "课程甲")
        XCTAssertEqual(cards[1].metrics.map(\.value), [405, 195, 600])
        XCTAssertEqual(cards[1].progress, 0.675)
        XCTAssertTrue(cards[2].notes.contains { $0.contains("已排除 1 条") })
        for card in cards { XCTAssertNoThrow(try card.validate()) }
    }
    func testUnknownDateAndCourseScopeDoNotPolluteDailyTotals() throws {
        let base = AssistantChartSimulation.snapshot()
        var state = base.state
        state.completions[0].taskID = UUID(); state.completions[0].studyDate = nil
        let snapshot = AssistantSnapshot(state: state, now: base.now, calendar: base.calendar)
        let queries = [try query("inspect_progress", ["start_date": "2026-09-14", "end_date": "2026-09-20", "course": AssistantSimulation.courseID.uuidString], snapshot: snapshot)]
        let card = try XCTUnwrap(AssistantInsights.build(queries, answer: "").first)
        XCTAssertEqual(card.metrics.map(\.value), [360, 510, 45])
        XCTAssertEqual(card.chart?.series[0].values.first, 0)
        XCTAssertTrue(card.subtitle.hasPrefix("指定课程"))
        XCTAssertTrue(card.notes.contains { $0.contains("未计入所选日期范围") })
    }
    func testPartialConflictPagesAreExplicitAndNotDoubleCounted() throws {
        let row: [String: Any] = ["kind": "constraint", "deadline": "2026-09-20", "required_minutes": 90, "available_minutes": 60]
        func page(_ offset: String, _ rows: [[String: Any]]) throws -> AssistantInsightQuery {
            let json = try AssistantWire.encode(["captured_at": "2026-09-14 08:00:00", "time_zone": "Asia/Shanghai", "data": ["total": 21, "rows": rows]])
            return .init(name: "inspect_conflicts", input: ["offset": offset], evidence: .init(id: "E1", category: "", json: json))
        }
        let first = try page("0", Array(repeating: row, count: 20))
        let partial = try XCTUnwrap(AssistantInsights.build([first, first], answer: "").first)
        XCTAssertEqual(partial.metrics.map(\.value), [21, 20, 0])
        XCTAssertTrue(partial.notes[0].contains("20/21"))
        XCTAssertEqual(partial.chart?.labels.count, 12)
        let last = try page("20", [["kind": "unbooked", "unscheduled_minutes": 30]])
        let complete = try XCTUnwrap(AssistantInsights.build([first, last, first], answer: "").first)
        XCTAssertEqual(complete.metrics.map(\.value), [21, 20, 1])
        XCTAssertEqual(complete.notes[0], "已读取全部提醒。")
    }
    func testEmptyAndInvalidQueriesNeverCreateFabricatedCards() throws {
        XCTAssertTrue(AssistantInsights.build([], answer: "课程完成 100%" ).isEmpty)
        let failed = try query("inspect_course", ["course": UUID().uuidString, "offset": "0"])
        XCTAssertTrue(AssistantInsights.build([failed], answer: "").isEmpty)
        let base = AssistantSimulation.snapshot()
        var state = PlannerState()
        state.courses = [Course(name: "空课程", totalMinutes: 0, startDate: base.now, deadline: base.now)]
        let snapshot = AssistantSnapshot(state: state, now: base.now, calendar: base.calendar)
        let card = try XCTUnwrap(AssistantInsights.build([try query("inspect_course", ["course": state.courses[0].id.uuidString, "offset": "0"], snapshot: snapshot)], answer: "").first)
        XCTAssertNil(card.progress)
        XCTAssertEqual(card.metrics.map(\.value), [0, 0, 0])
        let malformed = AssistantInsightQuery(name: "inspect_progress", input: [:], evidence: .init(id: "E1", category: "", json: "{}"))
        XCTAssertTrue(AssistantInsights.build([malformed], answer: "").isEmpty)
    }
    func testSnapshotHistoryCopyContextAndLegacyCompatibility() throws {
        let cards = AssistantInsights.build(try fixtures(), answer: "简短分析")
        let entry = AssistantChatEntry(role: "助手", text: "简短分析", status: "完成", insights: cards)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantHistoryStore(url: root.appendingPathComponent("history.json"))
        try store.save(.init(conversations: [.init(entries: [entry])]))
        let loaded = try XCTUnwrap(store.load().conversations.first?.entries.first)
        XCTAssertEqual(loaded.insights, cards)
        XCTAssertTrue(loaded.copyText.contains("2026-09-14\t45\t60"))
        XCTAssertTrue(loaded.hasVisualOverview)
        let encoded = String(decoding: try assistantJSON(loaded), as: UTF8.self)
        XCTAssertFalse(encoded.contains(AssistantSimulation.courseID.uuidString))
        XCTAssertFalse(encoded.contains("evidence_id")); XCTAssertFalse(encoded.contains("snapshot_id"))
        let messages = try AssistantConversationContext.messages(history: [loaded], memories: [], current: "继续")
        XCTAssertTrue(messages[0].content.contains("历史查询快照（不是当前事实）"))
        let legacy = AssistantChatEntry(role: "助手", text: "旧回复", status: "完成")
        XCTAssertNil(try JSONDecoder().decode(AssistantChatEntry.self, from: assistantJSON(legacy)).insights)
        var invalid = cards[0]; invalid.progress = .nan
        XCTAssertThrowsError(try invalid.validate())
    }
    func testMatchingInlineChartIsNotRepeatedInCard() throws {
        let queries = try fixtures()
        let chart = try XCTUnwrap(AssistantInsights.build(queries, answer: "").first?.chart)
        let answer = "```study-chart\n" + String(decoding: try assistantJSON(chart), as: UTF8.self) + "\n```"
        let card = try XCTUnwrap(AssistantInsights.build(queries, answer: answer).first)
        XCTAssertNil(card.chart)
        XCTAssertEqual(card.metrics[0].value, 405)
    }
    @MainActor func testSessionProducesCardsWithoutModelMarkupOrExtraRequests() async throws {
        try await AssistantInsightSimulation.probe()
        let base = AssistantSimulation.snapshot()
        let script = [("inspect_course", ["course": AssistantSimulation.courseID.uuidString, "offset": "0"]),
                      ("preview_edit_course", ["course": AssistantSimulation.courseID.uuidString, "field": "name", "value": "合成课程新名称"])]
        var cards: [AssistantInsight] = []
        let transport = AssistantMockTransport(script: script, answer: "核对方案")
        _ = try await AssistantRunner().run(configuration: AssistantSimulation.configuration(), messages: [.init(role: "user", content: "改名")], snapshot: base, key: "", transport: transport,
            currentSnapshotID: { base.id }, approve: { _ in true }, activity: { _ in }, evidence: { _ in }, insights: { cards = $0 })
        XCTAssertTrue(cards.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }
    @MainActor func testCardsRenderAtNarrowAndWideWidthsInBothAppearances() throws {
        _ = NSApplication.shared
        let cards = AssistantInsights.build(try fixtures(), answer: "")
        for width in [330.0, 680.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = VStack(spacing: 16) {
                    ForEach(cards.indices, id: \.self) { AssistantInsightView(insight: cards[$0]) }
                }.padding(12).frame(width: width).background(scheme == .dark ? Color(white: 0.08) : .white).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["STUDYPLANNER_INSIGHT_RENDER_DIR"] {
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("insights-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
