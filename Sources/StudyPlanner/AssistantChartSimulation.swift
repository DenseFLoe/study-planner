import Foundation
import StudyCore

/// Packaged acceptance uses only synthetic data, before the real store or credentials initialize.
enum AssistantChartSimulation {
    static let script: [(String, [String: String])] = [
        ("inspect_progress", ["start_date": "2026-09-14", "end_date": "2026-09-20", "course": ""]),
        ("inspect_course", ["course": AssistantSimulation.courseID.uuidString, "offset": "0"])
    ]
    static var answer: String {
        let labels = (14...20).map { "9/\($0)" }
        func block(_ title: String, kind: String, labels: [String], series: [[String: Any]]) -> String {
            let json = try! AssistantWire.encode(["title": title, "kind": kind, "unit": "分钟", "labels": labels, "series": series])
            return "```study-chart\n" + json + "\n```"
        }
        let trend = [["name": "实际学习", "values": (0..<7).map { "E1.data.days.\($0).actual_minutes" }],
                     ["name": "计划学习", "values": (0..<7).map { "E1.data.days.\($0).planned_by_start_day_minutes" }]]
        let progress = [["name": "有效进度", "values": ["E2.data.completed_minutes", "E2.data.remaining_minutes"]]]
        return "以下是合成课表的图表演示。指向图表可查看数值，切换图形或数据表无需再次查询。\n\n"
            + block("每日实际与计划", kind: "bar", labels: labels, series: trend) + "\n\n"
            + block("一周学习趋势", kind: "line", labels: labels, series: trend) + "\n\n"
            + block("课程完成情况", kind: "donut", labels: ["已完成", "剩余"], series: progress)
            + "\n\n计划量按任务开始日统计；实际学习用时与有效课程进度是不同口径。以上仅为合成演示数据。"
    }
    static func snapshot() -> AssistantSnapshot {
        let base = AssistantSimulation.snapshot()
        var state = base.state
        state.courses[0].type = .recorded
        state.courses[0].totalMinutes = 600
        state.courses[0].manualLessons = []
        state.tasks = []
        for (index, minutes) in [60, 90, 45, 80, 60, 100, 75].enumerated() {
            let day = base.calendar.date(byAdding: .day, value: index, to: base.now)!
            let task = ScheduledTask(courseID: AssistantSimulation.courseID, start: day, durationMinutes: minutes)
            state.tasks.append(task)
            try! state.confirm(taskID: task.id, actualMinutes: max(0, minutes - 15), now: day, calendar: base.calendar)
        }
        return .init(state: state, now: base.now, calendar: base.calendar)
    }
    @MainActor static func session() -> AssistantSession {
        let snapshot = snapshot()
        let session = AssistantSession(historyStore: nil, simulated: true, snapshot: { snapshot },
            transportFactory: { AssistantMockTransport(script: script, answer: answer) })
        session.configuration = AssistantSimulation.configuration()
        session.question = "用图表对比这一周每天的学习量，并展示课程完成情况。"
        return session
    }
    @MainActor static func probe() async throws {
        let snapshot = snapshot()
        for provider in AssistantProvider.allCases {
            let answer = try await AssistantRunner().run(configuration: AssistantSimulation.configuration(provider: provider),
                messages: [.init(role: "user", content: "生成学习图表")], snapshot: snapshot, key: "",
                transport: AssistantMockTransport(script: script, answer: self.answer), currentSnapshotID: { snapshot.id },
                approve: { _ in true }, activity: { _ in }, evidence: { _ in })
            let charts = AssistantMarkdown.blocks(answer).compactMap { block -> AssistantChart? in
                if case .chart(let chart) = block { return chart }; return nil
            }
            guard charts.map(\.kind) == [.bar, .line, .donut], charts[0].series[0].values == [45, 75, 30, 65, 45, 85, 60],
                  charts[2].series[0].values == [405, 195], !answer.contains("E1.data") else { throw AssistantError.protocolError }
        }
    }
}
