import Foundation

extension PlannerState {
    /// Validate the uncapped progress that course and lesson reconciliation sum.
    /// Missing-task legacy records still count at the top level; merged sources
    /// receive only the records associated with their existing task-ID prefixes.
    func validateRecordedProgress() throws {
        guard completions.allSatisfy({ $0.minutes >= 0 }) else { throw SyncFailure.invalidData }
        let tasksByCourse = Dictionary(grouping: tasks, by: \.courseID)
        let recordsByCourse = Dictionary(grouping: completions, by: \.courseID)
        typealias Node = (course: Course, prefix: String, tasks: [ScheduledTask], records: [CompletionRecord])
        var pending: [Node] = courses.map { ($0, "", tasksByCourse[$0.id] ?? [], recordsByCourse[$0.id] ?? []) }
        while let node = pending.popLast() {
            var total = max(0, node.course.initialCompletedMinutes)
            for record in node.records {
                let sum = total.addingReportingOverflow(record.minutes)
                guard !sum.overflow else { throw SyncFailure.invalidData }
                total = sum.partialValue
            }
            for source in node.course.mergedSources ?? [] {
                let prefix = node.prefix + source.id.uuidString + "/"
                let sourceTasks = node.tasks.filter { $0.lessonID?.hasPrefix(prefix) == true }
                let taskIDs = Set(sourceTasks.map(\.id))
                let sourceRecords = node.records.filter { taskIDs.contains($0.taskID) }
                pending.append((source, prefix, sourceTasks, sourceRecords))
            }
        }
    }
}
