import Foundation
import CryptoKit

/// Shared wire format v1. Payload is base64 JSON using the existing 2001 UTC epoch.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var payload: Data
    public var deleted: Bool
    public var version: Int64
    public var device: String
    public var sequence: Int64
    /// Unix milliseconds of the local edit, independent of unrelated ledger revisions.
    public var modifiedAt: Int64? = nil
    public var key: String { kind + "/" + id }
    public func wins(over other: SyncRecord) -> Bool {
        if (modifiedAt ?? 0) != (other.modifiedAt ?? 0) { return (modifiedAt ?? 0) > (other.modifiedAt ?? 0) }
        return version != other.version ? version > other.version : device > other.device
    }
}
public struct SyncLedger: Codable, Sendable {
    public var device = UUID().uuidString
    public var clock: Int64 = 0
    public var sequence: Int64 = 0
    public var peerCursor: Int64 = 0
    public var sentCursor: Int64 = 0
    public var records: [String: SyncRecord] = [:]
    public var lastAutoDate = ""
    public var lastSuccess: Double = 0
    public var lastAttempt: Double = 0
    public init() {}
    public static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public func permitsAutomatic(at date: Date) -> Bool {
        lastAutoDate != Self.day(date) && date.timeIntervalSince1970 - lastAttempt >= 1800
    }
    public func changes(after cursor: Int64) -> [SyncRecord] {
        records.values.filter { $0.sequence > cursor }.sorted { $0.sequence < $1.sequence }
    }
    public mutating func capture(_ state: PlannerState, now: Date = Date()) throws {
        var state = state
        state.removeArchivedCourses()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var desired: [String: SyncRecord] = [:]
        func add<T: Encodable>(_ kind: String, _ id: String, _ value: T) throws {
            var payload = try encoder.encode(value)
            if kind == "fixedEvents", var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                for field in ["weekdays", "excludedDates"] { if let items = object[field] as? [Double] { object[field] = items.sorted() } }
                payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
            let row = SyncRecord(kind: kind, id: id, payload: payload, deleted: false, version: 0, device: device, sequence: 0)
            desired[row.key] = row
        }
        for v in state.courses { try add("courses", v.id.uuidString, v) }
        for v in state.fixedEvents { try add("fixedEvents", v.id.uuidString, v) }
        for v in state.tasks { try add("tasks", v.id.uuidString, v) }
        for var v in state.completions { v.id = stablePlannerID("completion|" + v.taskID.uuidString); try add("completions", v.id.uuidString, v) }
        try add("settings", "settings", state.settings)
        var changed: [SyncRecord] = []
        for (key, var row) in desired {
            if let old = records[key], !old.deleted,
               try Self.equivalent(old.payload, row.payload) { continue }
            row.deleted = false; changed.append(row)
        }
        for (key, var row) in records where desired[key] == nil && !row.deleted {
            row.deleted = true; changed.append(row)
        }
        if changed.isEmpty { return }
        clock += 1
        for var row in changed.sorted(by: { $0.key < $1.key }) {
            sequence += 1; row.sequence = sequence; row.version = clock; row.device = device
            row.modifiedAt = max(Int64(now.timeIntervalSince1970 * 1000), (records[row.key]?.modifiedAt ?? 0) + 1)
            records[row.key] = row
        }
    }
    static func equivalent(_ a: Data, _ b: Data) throws -> Bool {
        // Local payloads use canonical JSON; most records are unchanged on a swap.
        if a == b { return true }
        let x = try JSONSerialization.jsonObject(with: a) as? NSDictionary
        let y = try JSONSerialization.jsonObject(with: b) as? NSDictionary
        return x == y
    }
    public mutating func merge(_ incoming: [SyncRecord]) throws {
        for var row in incoming {
            guard ["courses", "fixedEvents", "tasks", "completions", "settings"].contains(row.kind),
                  row.version > 0, row.version < Int64.max - 1_000_000,
                  (row.modifiedAt ?? 0) >= 0, (row.modifiedAt ?? 0) < Int64.max - 1_000_000,
                  !row.device.isEmpty, row.device.count <= 64,
                  (row.kind == "settings" ? row.id == "settings" : UUID(uuidString: row.id)?.uuidString == row.id),
                  row.payload.count <= 1_000_000 else { throw SyncFailure.invalidData }
            clock = max(clock, row.version)
            if let old = records[row.key], !row.wins(over: old) { continue }
            sequence += 1; row.sequence = sequence; records[row.key] = row
        }
    }
    public func materialize() throws -> PlannerState {
        let decoder = JSONDecoder(); var state = PlannerState()
        for row in records.values.sorted(by: { $0.key < $1.key }) where !row.deleted {
            switch row.kind {
            case "courses": let v = try decoder.decode(Course.self, from: row.payload); guard v.id.uuidString == row.id else { throw SyncFailure.invalidData }; state.courses.append(v)
            case "fixedEvents": let v = try decoder.decode(FixedEvent.self, from: row.payload); guard v.id.uuidString == row.id else { throw SyncFailure.invalidData }; state.fixedEvents.append(v)
            case "tasks": let v = try decoder.decode(ScheduledTask.self, from: row.payload); guard v.id.uuidString == row.id else { throw SyncFailure.invalidData }; state.tasks.append(v)
            case "completions": let v = try decoder.decode(CompletionRecord.self, from: row.payload); guard v.id.uuidString == row.id else { throw SyncFailure.invalidData }; state.completions.append(v)
            case "settings": state.settings = try decoder.decode(AppSettings.self, from: row.payload)
            default: throw SyncFailure.invalidData
            }
        }
        // A peer can confirm a task while its course is being deleted elsewhere.
        // Merges transfer those records; actual deletions still remove them.
        let deletedIDs = Set(records.values.filter { $0.kind == "courses" && $0.deleted }.compactMap { UUID(uuidString: $0.id) })
            .union(state.courses.filter(\.isArchived).map(\.id))
        let confirmationTasks = Set(state.completions.map(\.taskID))
        let deletedTasks = try records.values.filter {
            $0.kind == "tasks" && $0.deleted && UUID(uuidString: $0.id).map(confirmationTasks.contains) == true
        }.map {
            try decoder.decode(ScheduledTask.self, from: $0.payload)
        }
        try state.reconcileMergedCourseProgress(deletedIDs: deletedIDs, deletedTasks: deletedTasks)
        try reconcileConfirmations(in: &state)
        state.purgeDeletedLessonRecords(additionalTasks: deletedTasks)
        state.removeArchivedCourses()
        state.removeCourses(ids: deletedIDs)
        let ids = Set(state.courses.map(\.id))
        guard state.settings.minimumScheduleUnit > 0,
              state.tasks.allSatisfy({ ids.contains($0.courseID) && $0.durationMinutes > 0 }),
              state.completions.allSatisfy({ ids.contains($0.courseID) && $0.minutes >= 0 }) else { throw SyncFailure.invalidData }
        state.tasks.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        return state
    }
    /// Completion rows (including explicit undo tombstones) own confirmation state.
    /// A regenerated draft must never erase a confirmation just by having a newer task row.
    private func reconcileConfirmations(in state: inout PlannerState) throws {
        let decoder = JSONDecoder()
        var tasks = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) })
        for record in state.completions where tasks[record.taskID] == nil {
            if let row = records["tasks/" + record.taskID.uuidString], row.deleted {
                let old = try decoder.decode(ScheduledTask.self, from: row.payload)
                // A removed draft can still have been confirmed by the offline peer.
                if old.confirmedAt == nil { tasks[old.id] = old }
            }
        }
        let completions = Dictionary(uniqueKeysWithValues: state.completions.map { ($0.taskID, $0) })
        for id in tasks.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            var task = tasks[id]!
            let key = "completions/" + stablePlannerID("completion|" + id.uuidString).uuidString
            if let row = records[key], row.deleted {
                if task.confirmedAt != nil { task.status = .planned }
                task.confirmedAt = nil; task.completedMinutes = 0
            } else if let record = completions[id], record.courseID == task.courseID {
                guard record.minutes >= 0, record.minutes <= task.durationMinutes else { throw SyncFailure.invalidData }
                task.confirmedAt = record.recordedAt; task.completedMinutes = record.minutes
                task.status = record.minutes == 0 ? .missed : (record.minutes == task.durationMinutes ? .completed : .partial)
            }
            tasks[id] = task
        }
        // Old random IDs and stable IDs may describe the same lesson block.
        struct Slot: Hashable {
            var course: UUID; var lesson: String?; var start: Date; var duration: Int
            var windowStart: Date?; var windowEnd: Date?
        }
        var winners: [Slot: ScheduledTask] = [:]
        for task in tasks.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let slot = Slot(course: task.courseID, lesson: task.lessonID, start: task.start, duration: task.durationMinutes,
                            windowStart: task.floatingWindowStart, windowEnd: task.floatingWindowEnd)
            if let old = winners[slot] {
                if (task.confirmedAt != nil) != (old.confirmedAt != nil) {
                    if task.confirmedAt != nil { winners[slot] = task }
                    continue
                }
                let a = records["completions/" + stablePlannerID("completion|" + task.id.uuidString).uuidString]
                    ?? records["tasks/" + task.id.uuidString]!
                let b = records["completions/" + stablePlannerID("completion|" + old.id.uuidString).uuidString]
                    ?? records["tasks/" + old.id.uuidString]!
                if !a.wins(over: b) && b.wins(over: a) { continue }
            }
            winners[slot] = task
        }
        let kept = Set(winners.values.map(\.id))
        state.tasks = Array(winners.values)
        state.completions.removeAll { tasks[$0.taskID] != nil && !kept.contains($0.taskID) }
        // Backfill legacy task-only confirmations, but never override an explicit undo.
        for task in state.tasks where completions[task.id] == nil {
            if let confirmed = task.confirmedAt {
                state.completions.append(CompletionRecord(id: stablePlannerID("completion|" + task.id.uuidString),
                    courseID: task.courseID, taskID: task.id, minutes: task.completedMinutes, recordedAt: confirmed))
            }
        }
        state.completions.sort { $0.id.uuidString < $1.id.uuidString }
    }

}
public enum SyncFailure: Error, LocalizedError {
    case invalidData
    public var errorDescription: String? { "同步数据无效，未提交变更。" }
}
public func stablePlannerID(_ value: String) -> UUID {
    var b = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
    b[6] = (b[6] & 15) | 80; b[8] = (b[8] & 63) | 128
    return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
}
