import Foundation

/// Scheduling only: no credentials, transport or business data. Dates are supplied
/// by the caller so coalescing and completion races can be checked without sleeping.
struct CloudSyncSchedule {
    enum Trigger { case localChange, networkRestored, periodic, manual }
    static let periodicInterval: TimeInterval = 12 * 60 * 60
    static let minimumAutomaticInterval: TimeInterval = 30
    static let saveDebounce: TimeInterval = 2
    static let lastAttemptKey = "studyPlannerCloudLastAttempt.v1"

    private(set) var lastAttempt: Date?
    private(set) var networkAvailable: Bool?
    private(set) var running = false
    private var localChangeDue: Date?
    private var checkPending = false
    private var manualPending = false

    init(lastAttempt: Date? = nil) { self.lastAttempt = lastAttempt }

    mutating func request(_ trigger: Trigger, now: Date) {
        switch trigger {
        case .localChange: localChangeDue = now.addingTimeInterval(Self.saveDebounce)
        case .networkRestored: checkPending = true
        case .periodic:
            guard !running, lastAttempt.map({ now.timeIntervalSince($0) >= Self.periodicInterval }) ?? true else { return }
            checkPending = true
        case .manual: manualPending = true
        }
    }

    mutating func networkChanged(available: Bool, now: Date) {
        let previous = networkAvailable
        networkAvailable = available
        if previous == false && available { request(.networkRestored, now: now) }
    }

    func nextAttempt(at now: Date) -> Date? {
        guard !running else { return nil }
        if manualPending { return now }
        guard networkAvailable != false, localChangeDue != nil || checkPending else { return nil }
        return max(localChangeDue ?? now, lastAttempt?.addingTimeInterval(Self.minimumAutomaticInterval) ?? now)
    }

    mutating func began(at now: Date) {
        running = true; lastAttempt = now
        localChangeDue = nil; checkPending = false; manualPending = false
    }

    mutating func finished(success: Bool, hasLocalChanges: Bool, now: Date) {
        running = false
        if success {
            // The successful check covers concurrent network/periodic events.
            // Only edits still absent from the server need another automatic run.
            checkPending = false
            if hasLocalChanges {
                localChangeDue = localChangeDue ?? now.addingTimeInterval(Self.saveDebounce)
            } else { localChangeDue = nil }
        }
        // On failure, retain requests received DURING the attempt, but don't
        // invent an endless retry loop. Recovery, later edits or the timer retry.
    }

    mutating func cancelPending() {
        localChangeDue = nil; checkPending = false; manualPending = false
    }
}
