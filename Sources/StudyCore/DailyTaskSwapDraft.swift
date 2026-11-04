import Foundation

public enum DailyTaskSwapError: LocalizedError {
    case changed, pastDay
    public var errorDescription: String? {
        switch self {
        case .changed: "当天任务或顺序在保存前已有更新，未覆盖最新安排。请核对后重新交换。"
        case .pastDay: "保存时已跨到新一天，不能交换往日任务。请核对最新日程。"
        }
    }
}

/// Captures the displayed intent so saving cannot silently undo a concurrent swap.
public struct DailyTaskSwapDraft: Sendable {
    public let preview: PlannerState
    private let sourceID: UUID, targetID: UUID
    private let day: Date, calendar: Calendar
    private let before: Signature, after: Signature
    private struct Signature: Equatable, Sendable {
        let tasks: [ScheduledTask]
        let orders: [DailyTaskOrder]
        init(_ state: PlannerState, day: Date, calendar: Calendar) {
            tasks = state.tasks.filter { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: day) }
                .sorted { $0.id < $1.id }
            orders = (state.settings.dailyTaskOrders ?? []).filter { calendar.isDate($0.day, inSameDayAs: day) }
        }
    }
    public init(state: PlannerState, sourceID: UUID, targetID: UUID, now: Date = Date(), calendar: Calendar = .current) throws {
        guard let source = state.tasks.first(where: { $0.id == sourceID }) else { throw DailyTaskOrderError.unavailable }
        self.sourceID = sourceID; self.targetID = targetID; self.calendar = calendar
        day = calendar.startOfDay(for: source.start)
        before = Signature(state, day: day, calendar: calendar)
        var next = state
        try next.swapDailyTasks(sourceID, targetID, now: now, calendar: calendar)
        preview = next
        after = Signature(next, day: day, calendar: calendar)
    }
    public func apply(to state: inout PlannerState, now: Date = Date()) throws {
        guard day >= calendar.startOfDay(for: now) else { throw DailyTaskSwapError.pastDay }
        let latest = Signature(state, day: day, calendar: calendar)
        if latest == after { return }
        guard latest == before else { throw DailyTaskSwapError.changed }
        // Recompute placement against current windows, fixed events and pinned
        // study tasks, preserving unrelated courses and other days' changes.
        var next = state
        try next.swapDailyTasks(sourceID, targetID, now: now, calendar: calendar)
        state = next
    }
}
