import Foundation

public extension SyncLedger {
    /// A pending plan is a derived snapshot, not an append-only history. Select
    /// one plan per shared course; completion rows still merge independently.
    mutating func mergeCloudSnapshot(_ remote: SyncLedger, now: Date = Date()) throws {
        let localState = try materialize(), remoteState = try remote.materialize()
        let localCourses = Set(localState.courses.map(\.id)), remoteCourses = Set(remoteState.courses.map(\.id))
        func plans(_ state: PlannerState) -> [UUID: Set<UUID>] {
            Dictionary(grouping: state.tasks.filter(\.isUnconfirmed), by: \.courseID).mapValues { Set($0.map(\.id)) }
        }
        let a = plans(localState), b = plans(remoteState)
        let shared = localCourses.intersection(remoteCourses)
        let differing = Set(shared.filter { a[$0, default: []] != b[$0, default: []] })
        func revisions(_ ledger: SyncLedger) throws -> [UUID: SyncFieldVersion] {
            var result: [UUID: SyncFieldVersion] = [:]
            if differing.isEmpty { return result }
            for row in ledger.records.values.filter({ $0.kind == "tasks" }).sorted(by: { $0.fieldVersion.wins(over: $1.fieldVersion) }) {
                // Opaque legacy tombstones are permitted by the wire protocol.
                guard let task = try? JSONDecoder().decode(ScheduledTask.self, from: row.payload) else {
                    if row.deleted { continue }; throw SyncFailure.invalidData
                }
                if task.isUnconfirmed, differing.contains(task.courseID), result[task.courseID] == nil { result[task.courseID] = row.fieldVersion }
                if result.count == differing.count { break }
            }
            return result
        }
        let av = try revisions(self), bv = try revisions(remote)
        var keep = Set(localState.tasks.filter { !remoteCourses.contains($0.courseID) }.map(\.id))
        keep.formUnion(remoteState.tasks.filter { !localCourses.contains($0.courseID) }.map(\.id))
        for course in shared {
            if !differing.contains(course) { keep.formUnion(a[course, default: []]); continue }
            if let left = av[course], let right = bv[course] {
                guard left != right,
                      (left.modifiedAt > 0 && right.modifiedAt > 0)
                        || (left.modifiedAt > 0 && left.version > right.version)
                        || (right.modifiedAt > 0 && right.version > left.version) else { throw SyncFailure.invalidData }
                keep.formUnion(right.wins(over: left) ? b[course, default: []] : a[course, default: []])
            } else { keep.formUnion(av[course] != nil ? a[course, default: []] : b[course, default: []]) }
        }
        try merge(remote.changes(after: 0))
        var state = try materialize()
        state.tasks.removeAll { $0.isUnconfirmed && !keep.contains($0.id) }
        state.reconcileSavedSchedule(now: now)
        try capture(state, now: now)
    }
}
