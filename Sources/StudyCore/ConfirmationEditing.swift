import Foundation

public enum ConfirmationEditError: LocalizedError {
    case changed
    public var errorDescription: String? {
        "这项安排或完成记录在核对期间已更新，未保存确认或撤销。输入仍保留，请重新查看最新安排后再操作。"
    }
}

public extension PlannerState {
    /// Reload one confirmation form without changing the user's inputs or plan.
    /// Pausing automatic scheduling does not prevent confirming existing work.
    func pendingConfirmationTask(id: UUID) throws -> ScheduledTask {
        guard let task = tasks.first(where: { $0.id == id }), task.isUnconfirmed,
              courses.contains(where: { $0.id == task.courseID && !$0.isArchived }) else {
            throw PlannerError.alreadyConfirmed
        }
        return task
    }

    func checkReviewedTask(_ reviewed: ScheduledTask) throws {
        guard tasks.first(where: { $0.id == reviewed.id }) == reviewed else { throw ConfirmationEditError.changed }
    }

    mutating func confirm(reviewed: ScheduledTask, actualMinutes: Int, now: Date,
                          studyDate: Date? = nil, calendar: Calendar = .current) throws {
        try checkReviewedTask(reviewed)
        try confirm(taskID: reviewed.id, actualMinutes: actualMinutes, now: now, studyDate: studyDate, calendar: calendar)
    }

    mutating func undoConfirmation(reviewed: ScheduledTask, now: Date, calendar: Calendar = .current) throws {
        try checkReviewedTask(reviewed)
        try undoConfirmation(taskID: reviewed.id, now: now, calendar: calendar)
    }
}
