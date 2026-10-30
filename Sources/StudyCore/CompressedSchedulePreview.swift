import Foundation
import CoreFoundation
import CryptoKit

/// A bounded, derived display result. It is never fed into the ordinary scheduler.
public struct CompressedSchedulePreview: Codable, Equatable, Sendable {
    public struct CourseFinish: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var color: String
        public var remainingMinutes: Int
        public var finish: Date?
    }
    public struct Row: Codable, Equatable, Sendable {
        public var title: String
        public var color: String
        public var start: Date
        public var end: Date
        public var fixed: Bool
    }
    public var format = 1
    public var capturedAt: Date
    public var inputDay: String
    public var sourceSignature: String
    public var finish: Date?
    public var courses: [CourseFinish]
    public var rows: [Row]
    public var totalRows: Int

    public init(plan: CompressedSchedule, state: PlannerState) throws {
        capturedAt = plan.capturedAt; inputDay = SyncLedger.day(plan.capturedAt)
        sourceSignature = try Self.signature(state)
        finish = plan.finish
        courses = plan.courses.prefix(1000).map {
            CourseFinish(id: $0.course.id, name: String($0.course.name.prefix(120)), color: String($0.course.color.prefix(32)),
                         remainingMinutes: $0.remainingMinutes, finish: $0.finish)
        }
        let names = Dictionary(plan.courses.map { ($0.course.id, $0.course) }, uniquingKeysWith: { first, _ in first })
        let taskRows = plan.tasks.prefix(2000).map { task in
            Row(title: String(([names[task.courseID]?.name, task.lessonName].compactMap { $0 }.joined(separator: " · ")).prefix(240)),
                color: names[task.courseID]?.color ?? "blue", start: task.start, end: task.end, fixed: false)
        }
        let fixedRows = plan.fixed.prefix(2000).map {
            Row(title: String($0.event.title.prefix(240)), color: $0.event.color, start: $0.start, end: $0.end, fixed: true)
        }
        totalRows = plan.tasks.count + plan.fixed.count
        rows = Array((taskRows + fixedRows).sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }.prefix(2000))
        // Stay below the existing one-record wire limit, including unusually long titles.
        while try JSONEncoder().encode(self).count > 750_000 && !rows.isEmpty { rows.removeLast(min(100, rows.count)) }
        guard try JSONEncoder().encode(self).count <= 750_000 else { throw SyncFailure.invalidData }
    }

    /// The two platforms hash identical business inputs, ignoring draft order and display results.
    public static func signature(_ state: PlannerState) throws -> String {
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        func sorted(_ key: String) -> [[String: Any]] {
            (raw[key] as? [[String: Any]] ?? []).sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        }
        let tasks = sorted("tasks").filter { $0["confirmedAt"] != nil }.map { task in
            task.filter { ["id", "courseID", "lessonID"].contains($0.key) }
        }
        let windows = state.settings.availability.map {
            ["weekday": $0.weekday, "startMinute": $0.startMinute, "endMinute": $0.endMinute]
        }.sorted { ($0["weekday"]!, $0["startMinute"]!, $0["endMinute"]!) < ($1["weekday"]!, $1["startMinute"]!, $1["endMinute"]!) }
        let input: [String: Any] = ["courses": sorted("courses"), "fixedEvents": sorted("fixedEvents"),
            "completions": sorted("completions"), "tasks": tasks, "availability": windows,
            "minimumScheduleUnit": state.settings.minimumScheduleUnit]
        return SHA256.hash(data: Data(try canonical(input).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func canonical(_ value: Any, field: String = "") throws -> String {
        if let object = value as? [String: Any] {
            return "{" + (try object.keys.sorted().map { try canonical($0) + canonical(object[$0]!, field: $0) }.joined()) + "}"
        }
        if let array = value as? [Any] {
            var items = try array.map { try canonical($0) }
            if ["weekdays", "excludedDates", "deletedLessonIDs"].contains(field) { items.sort() }
            return "[" + items.joined() + "]"
        }
        if let text = value as? String { return "s\(text.utf8.count):\(text)" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return "n" + NSDecimalNumber(string: number.stringValue).stringValue + ";"
        }
        if value is NSNull { return "null" }
        throw SyncFailure.invalidData
    }
}
