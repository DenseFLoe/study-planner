import Foundation

public enum ConfirmationBatchError: LocalizedError {
    case empty, invalidMinutes, invalidStudyDate
    public var errorDescription: String? {
        switch self {
        case .empty: "请至少勾选一项已核对的安排。"
        case .invalidMinutes: "请核对已勾选项目的实际分钟数，须在 0 与该项计划分钟数之间。"
        case .invalidStudyDate: "请核对已勾选项目的学习日期，不能晚于今天。"
        }
    }
}

/// Captures only explicitly selected confirmations. Unselected rows may change
/// independently; every selected write succeeds together or leaves state intact.
public struct ConfirmationBatchDraft: Sendable {
    private struct Entry: Sendable {
        let task: ScheduledTask
        let minutes: Int
        let studyDate: Date
    }
    private let entries: [Entry]
    private let calendar: Calendar
    public var count: Int { entries.count }

    public init(reviewed tasks: [ScheduledTask], minutes: [UUID: Int], studyDates: [UUID: Date],
                now: Date = Date(), calendar: Calendar = .current) throws {
        guard !tasks.isEmpty else { throw ConfirmationBatchError.empty }
        guard Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy(\.isUnconfirmed) else {
            throw ConfirmationEditError.changed
        }
        self.calendar = calendar
        entries = try tasks.map { task in
            guard let value = minutes[task.id], value >= 0, value <= task.durationMinutes else {
                throw ConfirmationBatchError.invalidMinutes
            }
            let day = calendar.startOfDay(for: studyDates[task.id] ?? min(task.start, now))
            guard day <= calendar.startOfDay(for: now) else { throw ConfirmationBatchError.invalidStudyDate }
            return Entry(task: task, minutes: value, studyDate: day)
        }
    }

    public func requiresReplan(at now: Date) -> Bool {
        entries.contains { $0.task.confirmationRequiresReplan(actualMinutes: $0.minutes, now: now) }
    }

    public func apply(to state: inout PlannerState, now: Date = Date()) throws {
        let latest = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in entries where latest[entry.task.id] != entry.task { throw ConfirmationEditError.changed }
        var next = state
        for entry in entries {
            try next.confirm(taskID: entry.task.id, actualMinutes: entry.minutes, now: now,
                             studyDate: entry.studyDate, calendar: calendar)
        }
        state = next
    }
}
