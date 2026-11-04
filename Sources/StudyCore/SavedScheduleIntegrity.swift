import Foundation

public extension PlannerState {
    /// Drafts are derived data. Keep valid saved placements (including drag order)
    /// and regenerate only when a merged plan violates the winning constraints.
    @discardableResult
    mutating func reconcileSavedSchedule(now: Date, calendar: Calendar = .current) -> Bool {
        guard ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: self, now: now) else { return false }
        _ = replan(now: now, calendar: calendar)
        return true
    }
}

extension ScheduleEngine {
    public func hasInvalidSavedTasks(state: PlannerState, now: Date) -> Bool {
        let pending = state.tasks.filter { $0.isUnconfirmed && $0.planningEnd > now }.sorted { $0.start < $1.start }
        let courses = Dictionary(uniqueKeysWithValues: state.courses.map { ($0.id, $0) })
        let pause = Double(Self.breakMinutes * 60)
        let actualStart = state.settings.actualStudyStart(on: now, calendar: calendar)
        let immediate = state.validImmediateStudyTask(now: now, calendar: calendar)
        if let immediate, !pending.contains(immediate) { return true }
        var totals: [UUID: Int] = [:]
        var lessons: [UUID: [String: Int]] = [:]
        for task in pending {
            guard let course = courses[task.courseID], !course.isArchived, course.autoScheduleEnabled,
                  task.durationMinutes > 0,
                  calendar.startOfDay(for: task.start) >= calendar.startOfDay(for: course.startDate),
                  calendar.startOfDay(for: task.start) <= calendar.startOfDay(for: course.deadline) else { return true }
            if let actualStart, calendar.isDate(task.start, inSameDayAs: now), task.start < actualStart { return true }
            totals[course.id, default: 0] += task.durationMinutes
            if let lesson = task.lessonID { lessons[course.id, default: [:]][lesson, default: 0] += task.durationMinutes }
        }
        for course in state.courses {
            if totals[course.id, default: 0] > state.remainingMinutes(for: course) { return true }
            let remaining = Dictionary(uniqueKeysWithValues: state.lessonWorkItems(for: course).map { ($0.id, $0.remainingMinutes) })
            for (lesson, minutes) in lessons[course.id, default: [:]] where minutes > remaining[lesson, default: 0] { return true }
        }
        for (a, b) in zip(pending, pending.dropFirst()) where a.end.addingTimeInterval(pause) > b.start { return true }
        let history = mergeIntervals(state.tasks.filter {
            $0.planningStart < now && (($0.isUnconfirmed && $0.planningEnd <= now &&
                !(actualStart != nil && calendar.isDate($0.start, inSameDayAs: now))) || $0.completedMinutes > 0)
        }.map { task in
            let span = task.retainedHistoryInterval
            return (span.start.addingTimeInterval(-pause), span.end.addingTimeInterval(pause))
        })
        var index = 0
        for task in pending {
            while index < history.count && history[index].end <= task.start { index += 1 }
            if index < history.count && history[index].start < task.end { return true }
        }
        for (day, tasks) in Dictionary(grouping: pending, by: { calendar.startOfDay(for: $0.start) }) {
            let events = state.fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
            let exact = events.filter { !$0.isFloating }.map { (instant(day: day, minute: $0.startMinute), instant(day: day, minute: $0.endMinute)) }
            let windows = state.settings.availability.filter {
                $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute
            }.map { (instant(day: day, minute: $0.startMinute), instant(day: day, minute: $0.endMinute)) }
            let available = subtractIntervals(exact, from: windows)
            for task in tasks where !available.contains(where: { task.start >= $0.start && task.end <= $0.end }) { return true }
            let moving = tasks.map { ($0.start, $0.end) }
            let occupied = exact + moving
            let floating = events.filter(\.isFloating).sorted { $0.startMinute < $1.startMinute }
            func overlapsTasks(_ span: Interval) -> Bool { moving.contains { $0.0 < span.end && $0.1 > span.start } }
            func freeMinutes(_ span: Interval) -> Int { subtractIntervals(occupied, from: [span]).reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) } }
            var component: Interval?, required = 0
            for event in floating {
                let window = (start: instant(day: day, minute: event.startMinute), end: instant(day: day, minute: event.endMinute))
                // Only invalidate proven conflicts; a search-budget limit is not
                // evidence that an otherwise valid floating placement is impossible.
                if overlapsTasks(window), !subtractIntervals(occupied, from: [window]).contains(where: {
                    $0.end.timeIntervalSince($0.start) >= Double(event.occupiedMinutes) * 60
                }) { return true }
                if let old = component, window.start <= old.end {
                    component = (old.start, max(old.end, window.end)); required += event.occupiedMinutes
                } else {
                    if let old = component, overlapsTasks(old), freeMinutes(old) < required { return true }
                    component = window; required = event.occupiedMinutes
                }
            }
            if let component, overlapsTasks(component), freeMinutes(component) < required { return true }
        }
        return false
    }
}

private typealias Interval = (start: Date, end: Date)
private func mergeIntervals(_ spans: [Interval]) -> [Interval] {
    var result: [Interval] = []
    for span in spans.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
        if let last = result.last, span.start <= last.end { result[result.count - 1].end = max(last.end, span.end) }
        else { result.append(span) }
    }
    return result
}
private func subtractIntervals(_ blocks: [Interval], from windows: [Interval]) -> [Interval] {
    var result = mergeIntervals(windows)
    for block in mergeIntervals(blocks) {
        result = result.flatMap { span -> [Interval] in
            guard block.start < span.end, block.end > span.start else { return [span] }
            var parts: [Interval] = []
            if span.start < block.start { parts.append((span.start, block.start)) }
            if block.end < span.end { parts.append((block.end, span.end)) }
            return parts
        }
    }
    return result
}
