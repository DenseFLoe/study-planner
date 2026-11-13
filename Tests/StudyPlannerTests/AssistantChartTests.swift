import XCTest
import SwiftUI
import AppKit
@testable import StudyPlanner

final class AssistantChartTests: XCTestCase {
    private let stamp = "2026-09-20 18:00:00 Asia/Shanghai"
    private func evidence() throws -> [AssistantToolEvidence] {
        let snapshot = AssistantChartSimulation.snapshot()
        return try AssistantChartSimulation.script.enumerated().map {
            try AssistantTools.execute(name: $0.element.0, input: $0.element.1, snapshot: snapshot, id: "E\($0.offset + 1)")
        }
    }
    private func source(values: [Any] = ["E2.data.completed_minutes", "E2.data.remaining_minutes"],
                        kind: String = "bar", labels: [String] = ["已完成", "剩余"]) throws -> String {
        try AssistantWire.encode(["title": "课程进度", "kind": kind, "unit": "分钟", "labels": labels,
                                  "series": [["name": "有效进度", "values": values]]])
    }
    private func charts(_ text: String) -> [AssistantChart] {
        AssistantMarkdown.blocks(text).compactMap { if case .chart(let chart) = $0 { chart } else { nil } }
    }
    func testMaterializesAllThreeKindsFromRealNativeToolResults() throws {
        let text = AssistantCharts.materialize(AssistantChartSimulation.answer, evidence: try evidence(), capturedAt: stamp)
        let result = charts(text)
        XCTAssertEqual(result.map(\.kind), [.bar, .line, .donut])
        XCTAssertEqual(result[0].series[0].values, [45, 75, 30, 65, 45, 85, 60])
        XCTAssertEqual(result[0].series[1].values, [60, 90, 45, 80, 60, 100, 75])
        XCTAssertEqual(result[2].series[0].values, [405, 195])
        XCTAssertTrue(result.allSatisfy { $0.capturedAt == stamp })
        XCTAssertFalse(text.contains("E1.data"))
    }
    func testRejectsInventedStaleBooleanNullAndInvalidReferences() throws {
        let evidence = try evidence()
        for values: [Any] in [[405, 195], ["405", "195"], ["E9.data.total_minutes", "E2.data.remaining_minutes"],
                              ["E2.data.auto_schedule", "E2.data.remaining_minutes"],
                              ["E2.data.next_offset", "E2.data.remaining_minutes"],
                              ["E1.data.days.-1.actual_minutes", "E2.data.remaining_minutes"],
                              ["E1.data.days.0.actual_minutes + 1", "E2.data.remaining_minutes"]] {
            XCTAssertThrowsError(try AssistantCharts.resolve(source(values: values), evidence: evidence, capturedAt: stamp))
        }
    }
    func testRejectsMismatchedDuplicateAndExcessiveData() throws {
        let evidence = try evidence()
        for text in [try source(labels: ["一项"]), try source(labels: ["相同", "相同"]),
                     try source(kind: "html"), try source(labels: ["", "剩余"]),
                     try source(values: Array(repeating: "E2.data.total_minutes", count: 32), labels: (0..<32).map(String.init))] {
            XCTAssertThrowsError(try AssistantCharts.resolve(text, evidence: evidence, capturedAt: stamp))
        }
        XCTAssertThrowsError(try AssistantCharts.resolve(String(repeating: " ", count: 16_001), evidence: evidence, capturedAt: stamp))
    }
    func testDonutAndFiniteNumberGuardsAlsoApplyToSavedHistory() throws {
        for (kind, values): (AssistantChart.Kind, [Double]) in [(.donut, [0, 0]), (.donut, [-1, 10]),
                                                               (.bar, [.infinity, 0]), (.line, [1e13, 0])] {
            let chart = AssistantChart(title: "检查", kind: kind, unit: "分钟", labels: ["甲", "乙"],
                                       series: [.init(name: "数值", values: values)], capturedAt: stamp)
            XCTAssertThrowsError(try chart.validate())
            if let data = try? assistantJSON(chart) { XCTAssertNil(AssistantChart.decode(String(decoding: data, as: UTF8.self))) }
        }
        let zeroBar = AssistantChart(title: "零值", kind: .bar, unit: "分钟", labels: ["甲", "乙"],
                                    series: [.init(name: "数值", values: [0, 0])], capturedAt: stamp)
        XCTAssertNoThrow(try zeroBar.validate()); XCTAssertFalse(zeroBar.supportsDonut)
    }
    func testBrokenChartsPreserveAnswerAndOrdinaryCodeFences() throws {
        let ordinary = "```swift\nlet example = 1\n```"
        let answer = "前文\n\n```study-chart\n{}\n```\n\n" + ordinary + "\n\n后文"
        let result = AssistantCharts.materialize(answer, evidence: try evidence(), capturedAt: stamp)
        XCTAssertTrue(result.contains("前文")); XCTAssertTrue(result.contains("后文"))
        XCTAssertTrue(result.contains(ordinary)); XCTAssertTrue(result.contains(AssistantCharts.unavailable))
        XCTAssertTrue(charts(result).isEmpty)
        let unclosed = "```study-chart\n" + (try source())
        XCTAssertEqual(AssistantCharts.materialize(unclosed, evidence: try evidence(), capturedAt: stamp), AssistantCharts.unavailable)
        XCTAssertEqual(AssistantMarkdown.blocks("```study-chart\n{}\n```"), [.unavailableChart])
    }
    func testAnswerChartCountIsBoundedAndRawResolvedNumbersCannotBypassEvidence() throws {
        let block = "```study-chart\n" + (try source()) + "\n```"
        let resolved = AssistantCharts.materialize(Array(repeating: block, count: 4).joined(separator: "\n\n"),
                                                 evidence: try evidence(), capturedAt: stamp)
        XCTAssertEqual(charts(resolved).count, 3)
        XCTAssertTrue(resolved.contains(AssistantCharts.unavailable))
        let replay = AssistantCharts.materialize(resolved, evidence: [], capturedAt: stamp)
        XCTAssertTrue(charts(replay).isEmpty)
    }
    func testNativeChartHistoryRoundTripAndReadableCopy() throws {
        let answer = AssistantCharts.materialize(AssistantChartSimulation.answer, evidence: try evidence(), capturedAt: stamp)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chart-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssistantHistoryStore(url: root.appendingPathComponent("workspace.json"))
        let workspace = AssistantWorkspace(conversations: [.init(entries: [.init(role: "助手", text: answer, status: "完成")])])
        try store.save(workspace)
        let loaded = try XCTUnwrap(store.load().conversations.first?.entries.first?.text)
        XCTAssertEqual(charts(loaded), charts(answer))
        let copy = AssistantMarkdown.copyText(loaded)
        XCTAssertTrue(copy.contains("每日实际与计划")); XCTAssertTrue(copy.contains("9/14\t45\t60"))
        XCTAssertFalse(copy.contains("study-chart")); XCTAssertFalse(copy.contains("\"series\""))
    }
    @MainActor func testNativeRunnerSupportsAllProvidersWithoutAnotherRequestForCharts() async throws {
        try await AssistantChartSimulation.probe()
        let session = AssistantChartSimulation.session()
        session.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while session.busy, ContinuousClock.now < deadline {
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(session.busy); XCTAssertNil(session.message)
        XCTAssertEqual(charts(try XCTUnwrap(session.entries.last?.text)).count, 3)
        XCTAssertNil(session.pendingChange)
    }
    @MainActor func testChartsRenderAtNarrowAndWideWidthsInBothAppearances() throws {
        _ = NSApplication.shared
        let answer = AssistantCharts.materialize(AssistantChartSimulation.answer, evidence: try evidence(), capturedAt: stamp)
        for (width, scheme) in [(330.0, ColorScheme.light), (600.0, ColorScheme.dark)] {
            let content = VStack(spacing: 16) {
                ForEach(Array(charts(answer).enumerated()), id: \.offset) { _, chart in AssistantChartView(chart: chart) }
            }.padding(12).frame(width: width).background(scheme == .dark ? Color.black : .white).environment(\.colorScheme, scheme)
            // AppKit controls (segmented picker/buttons) aren't supported by ImageRenderer.
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(host.fittingSize.height, 900)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["STUDYPLANNER_CHART_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("charts-\(Int(width)).png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }
}
