import Foundation

/// Reconciles an open confirmation form with newly loaded pending tasks. This
/// changes only the form: no task or completion is created, deleted, or saved.
public struct DailyReviewRefresh: Sendable {
    public let tasks: [ScheduledTask]
    public let values: [UUID: Int]
    public let studyDates: [UUID: Date]
    public let reviewed: Set<UUID>
    public let changedIDs: Set<UUID>
    public let addedCount: Int
    public let removedCount: Int

    public init(previous: [ScheduledTask], latest: [ScheduledTask], values: [UUID: Int],
                studyDates: [UUID: Date], reviewed: Set<UUID>, now: Date = Date()) {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        tasks = latest.filter { $0.isUnconfirmed && seen.insert($0.id).inserted }
        let ids = Set(tasks.map(\.id))
        changedIDs = Set(tasks.filter { old[$0.id] != nil && old[$0.id] != $0 }.map(\.id))
        addedCount = ids.subtracting(old.keys).count
        removedCount = Set(old.keys).subtracting(ids).count
        // Do not clamp a retained input to a new duration: the user must see and
        // correct it. A changed task never inherits an earlier review decision.
        self.values = values.filter { ids.contains($0.key) }
        var dates = studyDates.filter { ids.contains($0.key) }
        for task in tasks where dates[task.id] == nil {
            // Preserve the date previously displayed even when the picker was
            // untouched and the latest plan moved this task to another day.
            if let previous = old[task.id] { dates[task.id] = min(previous.start, now) }
        }
        self.studyDates = dates
        self.reviewed = reviewed.intersection(ids).intersection(old.keys).subtracting(changedIDs)
    }
}
