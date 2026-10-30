import Foundation

/// Structural inputs for a sleeping baseline. Progress is intentionally absent:
/// every fresh calculation still receives the complete, current PlannerState.
public struct CompressedScheduleBasis: Codable, Equatable, Sendable {
    private struct Lesson: Codable, Equatable, Sendable {
        var id: String
        var minutes: Int
    }
    private struct CourseInput: Codable, Equatable, Sendable {
        var id: UUID
        var totalMinutes: Int
        var lessonBased: Bool
        var hasLessonSource: Bool
        var blockMinutes: Int
        var lessons: [Lesson]
    }
    private struct Window: Codable, Equatable, Sendable {
        var weekday: Int
        var start: Int
        var end: Int
    }
    private struct EventInput: Codable, Equatable {
        var startDate: Date
        var endDate: Date
        var startMinute: Int
        var endMinute: Int
        var weekday: Int
        var floatingMinutes: Int?
    }
    private var courses: [CourseInput]
    private var availability: [Window]
    private var events: [FixedEvent]

    public init(state: PlannerState) {
        courses = state.courses.filter { !$0.isArchived }.map { course in
            let lessons = state.lessonWorkItems(for: course)
            return CourseInput(id: course.id, totalMinutes: course.totalMinutes,
                lessonBased: course.type == .lessonBasedRecorded,
                hasLessonSource: course.type == .lessonBasedRecorded && (course.manualLessons?.isEmpty == false || course.webCourse != nil || course.mergedSources != nil),
                blockMinutes: lessons.isEmpty ? max(1, course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit) : 0,
                lessons: lessons.map { Lesson(id: $0.id, minutes: $0.durationMinutes) })
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        availability = []
        // IDs, row order and overlapping windows do not change usable capacity.
        for window in state.settings.availability.sorted(by: {
            ($0.weekday, $0.startMinute, $0.endMinute) < ($1.weekday, $1.startMinute, $1.endMinute)
        }) {
            if let last = availability.last, last.weekday == window.weekday, last.end >= window.startMinute {
                availability[availability.count - 1].end = max(last.end, window.endMinute)
            } else {
                availability.append(.init(weekday: window.weekday, start: window.startMinute, end: window.endMinute))
            }
        }
        events = state.fixedEvents.map {
            var event = $0
            event.title = ""; event.notes = ""; event.color = ""
            return event
        }
    }

    public func matches(_ other: Self, now: Date, calendar: Calendar) -> Bool {
        courses == other.courses && availability == other.availability &&
            futureEvents(now: now, calendar: calendar) == other.futureEvents(now: now, calendar: calendar)
    }

    private func futureEvents(now: Date, calendar: Calendar) -> [EventInput] {
        let today = calendar.startOfDay(for: now)
        let engine = ScheduleEngine(calendar: calendar)
        var inputs: [EventInput] = []
        func add(_ event: FixedEvent, from start: Date, through end: Date) {
            guard start <= end else { return }
            inputs.append(EventInput(startDate: start, endDate: end, startMinute: event.startMinute,
                endMinute: event.endMinute, weekday: calendar.component(.weekday, from: start),
                floatingMinutes: event.floatingDurationMinutes))
        }
        for event in events {
            let startDay = calendar.startOfDay(for: event.startDate)
            let endDay = calendar.startOfDay(for: event.endDate)
            guard endDay >= today else { continue }
            if event.weekdays.isEmpty {
                if event.occurs(on: startDay, calendar: calendar), engine.instant(day: startDay, minute: event.endMinute) > now {
                    add(event, from: startDay, through: startDay)
                }
                continue
            }
            // Represent occupied dates as weekly runs. This also makes a rule
            // split to protect history equivalent to its original future half.
            let lower = max(today, startDay)
            let excluded = Set(event.excludedDates.map { calendar.startOfDay(for: $0) })
            for weekday in event.weekdays.sorted() where (1...7).contains(weekday) {
                let offset = (weekday - calendar.component(.weekday, from: lower) + 7) % 7
                var first = calendar.date(byAdding: .day, value: offset, to: lower)!
                if engine.instant(day: first, minute: event.endMinute) <= now {
                    first = calendar.date(byAdding: .day, value: 7, to: first)!
                }
                let tail = (calendar.component(.weekday, from: endDay) - weekday + 7) % 7
                let last = calendar.date(byAdding: .day, value: -tail, to: endDay)!
                guard first <= last else { continue }
                for skipped in excluded.filter({ $0 >= first && $0 <= last && calendar.component(.weekday, from: $0) == weekday }).sorted() {
                    add(event, from: first, through: calendar.date(byAdding: .day, value: -7, to: skipped)!)
                    first = calendar.date(byAdding: .day, value: 7, to: skipped)!
                }
                add(event, from: first, through: last)
            }
        }
        let ordered = inputs.sorted {
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            if $0.endMinute != $1.endMinute { return $0.endMinute < $1.endMinute }
            if $0.floatingMinutes != $1.floatingMinutes { return ($0.floatingMinutes ?? -1) < ($1.floatingMinutes ?? -1) }
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.endDate < $1.endDate
        }
        var merged: [EventInput] = []
        for event in ordered {
            if let last = merged.last, last.weekday == event.weekday,
               last.startMinute == event.startMinute, last.endMinute == event.endMinute,
               last.floatingMinutes == event.floatingMinutes,
               calendar.date(byAdding: .day, value: 7, to: last.endDate) == event.startDate {
                merged[merged.count - 1].endDate = event.endDate
            } else { merged.append(event) }
        }
        return merged
    }
}

/// Complete local result; the bounded cloud preview remains a separate wire format.
public struct CompressedScheduleSnapshot: Codable, Sendable {
    public var version = 1
    public var basis: CompressedScheduleBasis
    public var calendar: Calendar
    public var plan: CompressedSchedule
    public var preview: CompressedSchedulePreview?

    public init(basis: CompressedScheduleBasis, calendar: Calendar, plan: CompressedSchedule, preview: CompressedSchedulePreview?) {
        self.basis = basis; self.calendar = calendar; self.plan = plan; self.preview = preview
    }
}
