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
            lines.append("本次混排尝试没能保留原方案已排入的学习量，曾将整份课表退回截止日期优先的排法。该排法容易让较早截止的课程连续占满前面的日期，不代表只有集中排课才能按期完成。")
            let other = result.adjustments.filter { $0 != deadlineFallback }
            if !other.isEmpty { lines.append("后续调整：" + other.joined(separator: "\n")) }
        } else if !result.adjustments.isEmpty {
            lines.append(result.adjustments.joined(separator: "\n"))
        } else {
            lines.append("本次没有触发整份课表的截止日期回退，按已保存的权重尽量排课；日期、空档、整节课与课节顺序始终优先满足。")
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
        lines.append("当前混排主要看一天有几门课，没有限制同一门连续几节；默认整理当天顺序时，也只在相同课程优先级之间交替。整节课和 15 分钟休息会进一步限制可用空档。")
        return lines
    }
}
