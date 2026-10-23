import Foundation

/// A read-only explanation of the last generated plan, using saved settings.
public enum ScheduleExplanation {
    public static let deadlineFallback = "为守住截止日期，已适当放宽每天的科目混排和学习倍率偏好。"

    public static func lines(state: PlannerState, result: ScheduleResult,
                             calendar: Calendar = .current) -> [String] {
        let courses = state.courses.filter {
            !$0.isArchived && $0.autoScheduleEnabled && state.remainingMinutes(for: $0) > 0
        }
        guard !courses.isEmpty else { return ["当前没有需要自动排课的剩余课程。"] }
        var lines: [String] = []
        if result.adjustments.contains(deadlineFallback) {
            lines.append("初始混排尝试没能保留原方案已排入的学习量，曾将整份课表退回截止日期优先的排法，随后继续按权重尝试局部优化。仍有集中安排不代表只有集中排课才能按期完成。")
            let other = result.adjustments.filter { $0 != deadlineFallback }
            if !other.isEmpty { lines.append("后续调整：" + other.joined(separator: "\n")) }
        } else if !result.adjustments.isEmpty {
            lines.append(result.adjustments.joined(separator: "\n"))
        } else {
            lines.append("本次没有触发初始混排的截止日期回退，按已保存的权重比较完整课表并尝试优化；日期、空档、整节课与课节顺序始终优先满足。")
        }
        let earliest = courses.map { calendar.startOfDay(for: $0.deadline) }.min()!
        let names = courses.filter { calendar.startOfDay(for: $0.deadline) == earliest }.map(\.name).sorted()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let date = formatter.string(from: earliest)
        lines.append("较早截止：\(names.joined(separator: "、"))（\(date)）。截止日期优先的方案会先为它们占用前面的时段。")
        let boosted = courses.filter { $0.dailyWeight > 1 }.sorted { $0.name < $1.name }
        if boosted.isEmpty {
            lines.append("当前没有每日加量课程，集中排课并非加量造成。")
        } else {
            let weights = boosted.map { "\($0.name) \(String(format: "%g", $0.dailyWeight)) 倍" }
            let triple = courses.contains { $0.dailyWeight == 3 }
            let suffix = !triple ? "当前没有 3 倍课程。"
                : (state.settings.schedulePriorities.usesDefaultOrder ? "默认规则允许能排入的 3 倍课程优先集中学习。" : "自定义顺序下不启用默认的 3 倍集中例外。")
            lines.append("每日加量：\(weights.joined(separator: "、"))，会倾向前面的日期。\(suffix)")
        }
        lines.append("当前偏好顺序：" + state.settings.schedulePriorities.orderedRules.map(\.title).joined(separator: " → ") + "；同级沿用默认顺序。")
        lines.append("混排同时比较每天的科目数量和同科连续安排；较低级偏好不能抵消更高级偏好的损失。优化保留每门课程已排入的学习量、整节课顺序和 15 分钟休息；搜索有预算上限，不保证全局最优。")
        return lines
    }
}
