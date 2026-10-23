import Foundation

/// The existing soft scheduling preferences. Time and progress constraints always
/// remain mandatory; changing these levels never relaxes them.
public enum ScheduleRule: String, CaseIterable, Identifiable, Sendable {
    case diversity, dailyWeight, coursePriority, balancedLoad

    public var id: String { rawValue }
    public var defaultLevel: Int {
        switch self {
        case .diversity: 1
        case .dailyWeight: 2
        case .coursePriority: 3
        case .balancedLoad: 4
        }
    }
    public var title: String {
        switch self {
        case .diversity: "多科混排、分散学习"
        case .dailyWeight: "每日加量"
        case .coursePriority: "课程优先级"
        case .balancedLoad: "学习量均衡"
        }
    }
    public var explanation: String {
        switch self {
        case .diversity: "时间允许时，一天尽量安排多个科目并交替学习，同时为后续日期保留混排机会。"
        case .dailyWeight: "按各课程已有的 1～3 倍率提高前面日期的目标学习量；空间不足时允许延后到后续日期。"
        case .coursePriority: "在其他更高优先级的规则相同时，让课程编辑中设置为较高优先级的课程更早安排。"
        case .balancedLoad: "比较各天的总学习分钟数并尽量均衡；整节课也计入比较，且保持整节完整和顺序。"
        }
    }
}

public struct SchedulePriorities: Equatable, Sendable {
    public var levels: [String: Int]
    public init(levels: [String: Int] = [:]) {
        self.levels = Dictionary(uniqueKeysWithValues: ScheduleRule.allCases.map { rule in
            (rule.rawValue, min(4, max(1, levels[rule.rawValue] ?? rule.defaultLevel)))
        })
    }
    public func level(_ rule: ScheduleRule) -> Int { levels[rule.rawValue] ?? rule.defaultLevel }
    /// Stable ties keep the existing rule order, on both platforms.
    public var orderedRules: [ScheduleRule] {
        ScheduleRule.allCases.sorted {
            level($0) != level($1) ? level($0) < level($1) : $0.defaultLevel < $1.defaultLevel
        }
    }
    public var usesDefaultOrder: Bool { orderedRules == ScheduleRule.allCases }
}

extension AppSettings {
    public var schedulePriorities: SchedulePriorities {
        get { SchedulePriorities(levels: schedulingRuleLevels ?? [:]) }
        set { schedulingRuleLevels = newValue == SchedulePriorities() ? nil : newValue.levels }
    }
}
