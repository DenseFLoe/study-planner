import Foundation

enum AssistantInsightSimulation {
    static let script = AssistantChartSimulation.script + [
        ("inspect_schedule", ["date": "2026-09-14", "offset": "0"]),
        ("inspect_conflicts", ["offset": "0"]),
        ("inspect_rules", [:])
    ]
    @MainActor static func session() -> AssistantSession {
        let snapshot = AssistantChartSimulation.snapshot()
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot },
            transportFactory: { AssistantMockTransport(script: script, answer: "这一周的实际学习量低于计划量，课程还有剩余学习内容。可结合每日趋势与日程核对结果调整接下来的安排。以上仅为合成演示数据。") })
        session.configuration = AssistantSimulation.configuration()
        session.question = "看看课程进度、这周学习统计和排程情况。"
        return session
    }
    @MainActor static func probe() async throws {
        let session = session()
        session.send()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while session.busy, ContinuousClock.now < deadline {
            if let approval = session.approval { session.decide(approval.id, allow: true) }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !session.busy, session.message == nil, let entry = session.entries.last,
              let cards = entry.insights, cards.map(\.kind) == [.statistics, .course, .schedule, .conflicts, .rules],
              cards[0].metrics[0].value == 405, cards[0].chart?.series[0].values == [45, 75, 30, 65, 45, 85, 60],
              cards[1].progress == 0.675, entry.changeSummary == nil,
              entry.copyText.contains("每日实际与计划") else { throw AssistantError.protocolError }
        let loaded = try JSONDecoder().decode(AssistantChatEntry.self, from: assistantJSON(entry))
        guard loaded.insights == cards else { throw AssistantError.history }
    }
}
