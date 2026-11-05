import Foundation

public struct SyncFieldVersion: Codable, Equatable, Sendable {
    public var modifiedAt: Int64
    public var version: Int64
    public var device: String
    func wins(over other: Self) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        return version != other.version ? version > other.version : device > other.device
    }
}

extension SyncRecord {
    var fieldVersion: SyncFieldVersion { .init(modifiedAt: modifiedAt ?? 0, version: version, device: device) }
    // Lesson sources, deletions, order and credited source progress form one coherent unit.
    private static func group(_ key: String) -> String {
        let lessons: Set<String> = ["totalMinutes", "initialCompletedMinutes", "webCourse", "webCompletionOverlaps", "netdisk", "netdiskLessons", "manualLessons", "lessonOrder", "lessonOrderCustomized", "deletedLessonIDs", "mergedSources", "type"]
        return lessons.contains(key) ? "$lessons" : key
    }
    private static func groups(_ object: [String: Any]) -> [String: NSDictionary] {
        var result: [String: [String: Any]] = [:]
        for (key, value) in object where key != "id" { result[group(key), default: [:]][key] = value }
        return result.mapValues { $0 as NSDictionary }
    }
    func validateFieldVersions() throws {
        guard let fieldVersions else { return }
        guard kind == "courses", fieldVersions.count <= 128,
              fieldVersions.allSatisfy({ key, stamp in
                  !key.isEmpty && key.count <= 128 && stamp.modifiedAt >= 0 && stamp.modifiedAt <= (modifiedAt ?? 0)
                    && stamp.version > 0 && stamp.version <= version && !stamp.device.isEmpty && stamp.device.count <= 64
              }) else { throw SyncFailure.invalidData }
    }
    mutating func captureCourseFields(previous: SyncRecord?) throws {
        guard kind == "courses", !deleted else { fieldVersions = nil; return }
        let current = Self.groups(try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:])
        guard let previous, !previous.deleted else {
            fieldVersions = current.mapValues { _ in fieldVersion }; return
        }
        let old = Self.groups(try JSONSerialization.jsonObject(with: previous.payload) as? [String: Any] ?? [:])
        var stamps = previous.fieldVersions ?? [:]
        for key in Set(current.keys).union(old.keys) {
            stamps[key] = current[key] == old[key] ? (stamps[key] ?? previous.fieldVersion) : fieldVersion
        }
        fieldVersions = stamps
    }
    func mergingCourseFields(with other: SyncRecord) throws -> SyncRecord {
        let winner = wins(over: other) ? self : other
        guard kind == "courses", !deleted, !other.deleted, fieldVersions != nil || other.fieldVersions != nil else { return winner }
        guard let left = try JSONSerialization.jsonObject(with: payload) as? [String: Any], left["id"] as? String == id,
              let right = try JSONSerialization.jsonObject(with: other.payload) as? [String: Any], right["id"] as? String == other.id else { throw SyncFailure.invalidData }
        let a = Self.groups(left), b = Self.groups(right)
        var object: [String: Any] = ["id": id], stamps: [String: SyncFieldVersion] = [:]
        let keys = Set(a.keys).union(b.keys).union(fieldVersions?.keys.map { $0 } ?? []).union(other.fieldVersions?.keys.map { $0 } ?? [])
        for key in keys {
            let av = fieldVersions?[key] ?? fieldVersion, bv = other.fieldVersions?[key] ?? other.fieldVersion
            guard av != bv || a[key] == b[key] else { throw SyncFailure.invalidData }
            let useA = av.wins(over: bv)
            stamps[key] = useA ? av : bv
            if let selected = useA ? a[key] : b[key] {
                for (name, value) in selected { object[name as! String] = value }
            }
        }
        var result = winner
        result.payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        result.fieldVersions = stamps
        // The server may still implement row-level LWW. Publish a combined payload
        // with a strictly newer header while retaining each field's original stamp.
        if try SyncLedger.equivalent(result.payload, winner.payload), stamps == winner.fieldVersions { return winner }
        result.version = max(version, other.version) + 1
        result.modifiedAt = max(modifiedAt ?? 0, other.modifiedAt ?? 0) + 1
        return result
    }
}
