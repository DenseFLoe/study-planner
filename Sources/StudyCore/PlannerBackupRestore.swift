import Foundation

public enum PlannerBackupRestoreError: LocalizedError {
    case changed
    public var errorDescription: String? {
        "日程在核对备份期间已有更新，未执行恢复。请重新选择备份并核对最新记录。"
    }
}

/// Full replacement requires the complete reviewed state to remain unchanged.
public struct PlannerBackupRestore: Sendable {
    private let backup: PlannerBackup
    private let reviewed: PlannerState
    private let validUntil: Date?

    public init(backup: PlannerBackup, reviewedState: PlannerState, validUntil: Date? = nil) {
        self.backup = backup
        reviewed = reviewedState
        self.validUntil = validUntil
    }

    private static func comparable(_ state: PlannerState) -> PlannerState {
        var value = state
        // Persistence and display can enumerate these keyed rows differently.
        value.courses.sort { $0.id < $1.id }
        value.fixedEvents.sort { $0.id < $1.id }
        value.tasks.sort { $0.id < $1.id }
        value.completions.sort { $0.id < $1.id }
        value.settings.availability.sort { $0.id < $1.id }
        return value
    }

    public func apply(to state: inout PlannerState) throws {
        guard validUntil.map({ Date() < $0 }) ?? true else { throw PlannerBackupRestoreError.changed }
        guard Self.comparable(state) == Self.comparable(reviewed) else { throw PlannerBackupRestoreError.changed }
        var replacement = try backup.validated().state
        replacement.removeArchivedCourses()
        guard validUntil.map({ Date() < $0 }) ?? true else { throw PlannerBackupRestoreError.changed }
        state = replacement
    }
}
