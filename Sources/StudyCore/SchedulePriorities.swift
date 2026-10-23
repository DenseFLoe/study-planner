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
        case .diversity: "时间允许时，一天安排多个科目，并为后续日期保留混排机会。"
        case .dailyWeight: "按照各课程已有的 1～3 倍加量设置，优先把学习量排到前面的日期。"
        case .coursePriority: "优先安排课程编辑中设置为较高优先级的课程。"
        case .balancedLoad: "尽量均衡各天的学习量，避免普通时间块集中在少数日期。按节课程仍保持整节和顺序。"
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
