import Foundation

/// Calendar visibility and totals derived once from a value snapshot.
public struct CalendarDaySnapshot: Sendable {
    public let tasks: [ScheduledTask]
    public let events: [FixedEvent]
    public let skipped: [FixedEvent]
    public let plannedMinutes: Int?
    public let floatingMinutes: Int?
    private let courses: [UUID: Course]
    public func course(_ id: UUID) -> Course? { courses[id] }

    public static func visibleTasks(_ tasks: [ScheduledTask], courses: [Course]) -> [ScheduledTask] {
        let active = Set(courses.filter { !$0.isArchived }.map(\.id))
        return tasks.filter { !$0.isUnconfirmed || active.contains($0.courseID) }
    }

    public init(state: PlannerState, day: Date, calendar: Calendar = .current) {
        let byID = Dictionary(state.courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        courses = byID
        tasks = state.tasks.filter {
            calendar.isDate($0.start, inSameDayAs: day) && (byID[$0.courseID]?.isArchived == false || !$0.isUnconfirmed)
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        var active: [FixedEvent] = [], removed: [FixedEvent] = []
        for event in state.fixedEvents where event.occurs(on: day, calendar: calendar, includingExcluded: true) {
            if event.occurs(on: day, calendar: calendar) { active.append(event) } else { removed.append(event) }
        }
        func order(_ lhs: FixedEvent, _ rhs: FixedEvent) -> Bool {
            lhs.startMinute == rhs.startMinute ? lhs.id.uuidString < rhs.id.uuidString : lhs.startMinute < rhs.startMinute
        }
        events = active.sorted(by: order); skipped = removed.sorted(by: order)
        func sum(_ values: [Int]) -> Int? {
            var total = 0
            for value in values {
                guard value >= 0 else { return nil }
                let next = total.addingReportingOverflow(value)
                guard !next.overflow else { return nil }
                total = next.partialValue
            }
            return total
        }
        plannedMinutes = sum(tasks.filter(\.isUnconfirmed).map(\.durationMinutes))
        floatingMinutes = sum(active.compactMap(\.floatingDurationMinutes))
    }
}
