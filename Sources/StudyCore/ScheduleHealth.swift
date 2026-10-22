import Foundation

public struct ScheduleConstraintConflict: Sendable, Equatable {
    public var windowStart: Date
    public var deadline: Date
    public var requiredMinutes: Int
    public var availableMinutes: Int
    public var courseNames: [String]
    public var minimumContinuousMinutes: Int? = nil
    /// A lower bound, not the scheduler's arbitrary unbooked amount.
    public var provenDeficit: Int? { minimumContinuousMinutes == nil ? max(0, requiredMinutes - availableMinutes) : nil }
}

public struct ScheduleDayPlan: Sendable, Equatable, Identifiable {
    public var id: Date { date }
    public var date: Date
    public var availableMinutes: Int
    public var plannedMinutes: Int
}

public struct ScheduleHealth: Sendable {
    public enum Status: Sendable { case scheduled, heavy, pending, shortage }
    public var status: Status
    public var remainingMinutes: Int
    public var unscheduledMinutes: Int
    public var pausedMinutes: Int
    public var peakMinutes: Int
    public var heavyDays: Int
    public var averageMinutes: Double
    public var reviewedMinutes: Int
    public var creditedMinutes: Int
    public var recovery: [ScheduleDayPlan]
    public var dayPlans: [ScheduleDayPlan]
    public var title: String {
        switch status {
        case .scheduled: "已安排 · 仍可按期完成"
        case .heavy: "能按期排完 · 学习负担偏重"
        case .pending: "当前方案还没排好"
        case .shortage: "已确认存在时间约束冲突"
        }
    }
    public var explanation: String {
        switch status {
        case .scheduled: "剩余学习量已全部排入，截止日期保持不变。"
        case .heavy: "已有完整课表，但部分日期学习时间较长。请查看每天的负担。"
        case .pending: "尚未找到完整排法，不等于客观上学不完。请查看未排入内容和可调整的时段。"
        case .shortage: "已发现总时长或连续空档无法满足的硬约束。请查看具体原因。"
        }
    }
}

public struct ScheduleHealthAnalyzer: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }
    public func assess(state: PlannerState, result: ScheduleResult, now: Date, heavyDayMinutes: Int = 480) -> ScheduleHealth? {
        let courses = state.courses.filter { !$0.isArchived && state.remainingMinutes(for: $0) > 0 }
        guard !courses.isEmpty else { return nil }
        let planned = Dictionary(grouping: result.tasks, by: \.courseID).mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }
        let missing = courses.filter(\.autoScheduleEnabled).reduce(0) { $0 + max(0, state.remainingMinutes(for: $1) - planned[$1.id, default: 0]) }
        let paused = courses.filter { !$0.autoScheduleEnabled }.reduce(0) { $0 + state.remainingMinutes(for: $1) }
        let days = result.dayPlans.filter { $0.plannedMinutes > 0 }
        let heavy = days.filter { $0.plannedMinutes > max(30, heavyDayMinutes) }.count
        let status: ScheduleHealth.Status = !result.conflicts.isEmpty ? .shortage
            : (missing > 0 || paused > 0 || !result.diagnostics.isEmpty ? .pending : (heavy > 0 ? .heavy : .scheduled))
        let reviewed = state.tasks.filter { $0.confirmedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        struct DebtKey: Hashable { var course: UUID; var lesson: String? }
        var recoveryBudget: [DebtKey: Int] = [:]
        for course in courses {
            let remaining = Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: course).map { ($0.id, $0.remainingMinutes) })
            for task in reviewed where task.courseID == course.id && task.completedMinutes < task.durationMinutes {
                let key = DebtKey(course: course.id, lesson: task.lessonID)
                let cap = task.lessonID.flatMap { remaining[$0] } ?? state.remainingMinutes(for: course)
                let debt = min(cap, task.durationMinutes - task.completedMinutes)
                // Repeated attempts on the same lesson must not create extra debt.
                if task.lessonID != nil { recoveryBudget[key] = max(recoveryBudget[key, default: 0], debt) }
                else { recoveryBudget[key] = min(cap, recoveryBudget[key, default: 0] + debt) }
            }
        }
        var recovery: [Date: Int] = [:]
        for task in result.tasks.sorted(by: { $0.start < $1.start }) {
            let key = DebtKey(course: task.courseID, lesson: task.lessonID)
            let amount = min(task.durationMinutes, recoveryBudget[key, default: 0])
            if amount > 0 { recovery[calendar.startOfDay(for: task.start), default: 0] += amount; recoveryBudget[key]! -= amount }
        }
        return .init(status: status, remainingMinutes: courses.reduce(0) { $0 + state.remainingMinutes(for: $1) },
                     unscheduledMinutes: missing, pausedMinutes: paused, peakMinutes: days.map(\.plannedMinutes).max() ?? 0,
                     heavyDays: heavy, averageMinutes: days.isEmpty ? 0 : Double(days.reduce(0) { $0 + $1.plannedMinutes }) / Double(days.count),
                     reviewedMinutes: reviewed.reduce(0) { $0 + $1.durationMinutes }, creditedMinutes: reviewed.reduce(0) { $0 + $1.completedMinutes },
                     recovery: recovery.keys.sorted().map { .init(date: $0, availableMinutes: 0, plannedMinutes: recovery[$0]!) }, dayPlans: days)
    }
}
