import Foundation
import StudyCore

/// A local, read-only snapshot of a proposal. Never stores the planner states or
/// gives a historical card the ability to apply a change.
struct AssistantChangeSummary: Codable, Equatable, Sendable {
    struct Count: Codable, Equatable, Sendable {
        let category: String
        let added: Int
        let modified: Int
        let removed: Int
        var total: Int { added + modified + removed }
        var text: String { "\(category)：新增 \(added)，修改 \(modified)，删除 \(removed)" }
    }
    let title: String
    let highlights: [String]
    let counts: [Count]
    let conflictCount: Int
    let unscheduledDeadlineCount: Int
    let workload: AssistantChart?
    let capturedAt: String

    var added: Int { counts.reduce(0) { $0 + $1.added } }
    var modified: Int { counts.reduce(0) { $0 + $1.modified } }
    var removed: Int { counts.reduce(0) { $0 + $1.removed } }
    var unchangedCategories: String { counts.filter { $0.total == 0 }.map(\.category).joined(separator: "、") }
    var warnings: String {
        "排程约束冲突：\(conflictCount) 项；有未排入量的截止日期：\(unscheduledDeadlineCount) 个。未排入量不代表无解。"
    }
    var plainText: String {
        ([title, "生成时的修改预览 · " + capturedAt] + highlights + counts.map(\.text) + [warnings]
            + (workload.map { [$0.title, $0.tableText, Self.workloadNote] } ?? [])).joined(separator: "\n")
    }
    static let workloadNote = "按任务开始日统计计划分钟，含已确认任务的原计划，不是实际已学或剩余学习量。仅展示今天起 7 天；完整修改见全部差异。"

    func validate() throws {
        guard title.count <= 300, capturedAt.count <= 100, highlights.count <= 8,
              highlights.allSatisfy({ $0.count <= 1000 }), counts.count == 4,
              counts.map(\.category) == ["课程", "事项", "学习任务", "学习记录"],
              counts.allSatisfy({ [ $0.added, $0.modified, $0.removed ].allSatisfy { (0...10_000).contains($0) } }),
              (0...100_000).contains(conflictCount), (0...100_000).contains(unscheduledDeadlineCount)
        else { throw AssistantError.history }
        if let workload {
            try workload.validate()
            guard workload.labels.count == 7, workload.series.count == 2,
                  workload.series.allSatisfy({ $0.values.allSatisfy { $0 >= 0 } }) else { throw AssistantError.history }
        }
    }

    static func workload(before: PlannerState, after: PlannerState, snapshot: AssistantSnapshot) -> AssistantChart? {
        let calendar = snapshot.calendar, today = calendar.startOfDay(for: snapshot.now)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: today)! }
        func values(_ state: PlannerState) -> [Double] {
            let totals = Dictionary(grouping: state.tasks, by: { calendar.startOfDay(for: $0.start) })
                .mapValues { $0.reduce(0.0) { $0 + Double($1.durationMinutes) } }
            return days.map { totals[$0, default: 0] }
        }
        // A rename or a same-day reorder needs counts, not an identical chart.
        let old = values(before), new = values(after)
        guard old != new else { return nil }
        return .init(title: "未来 7 天计划学习量", kind: .bar, unit: "分钟",
                     labels: days.map { "\(calendar.component(.month, from: $0))/\(calendar.component(.day, from: $0))" },
                     series: [.init(name: "修改前", values: old), .init(name: "方案预览", values: new)],
                     capturedAt: snapshot.stamp(snapshot.now, time: true) + " " + calendar.timeZone.identifier)
    }
}

extension AssistantChatEntry {
    var copyText: String {
        AssistantMarkdown.copyText(text) + (changeSummary.map { "\n\n" + $0.plainText } ?? "")
    }
}
