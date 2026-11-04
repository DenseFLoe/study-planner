import Foundation

/// Stable identities survive the scheduler regenerating task IDs and start times.
public struct DailyTaskOrder: Codable, Equatable, Sendable {
    public var day: Date
    public var keys: [String]

    static func keys(for tasks: [ScheduledTask]) -> [String] {
        var counts: [String: Int] = [:]
        return tasks.map {
            let base = "\($0.courseID)|\($0.lessonID ?? "")|\($0.durationMinutes)"
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            return "\(base)|\(occurrence)"
        }
    }
}

public enum DailyTaskOrderError: Error, LocalizedError {
    case unavailable, noSpace
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "只能交换同一天的两个不同未确认学习板块，请刷新后重试。"
        case .noSpace: return "交换后无法在当天可学习时段内保留课程时长和课间休息，请调整可学习时间或选择其他板块。"
        }
    }
}

extension PlannerState {
    public mutating func swapDailyTasks(_ sourceID: UUID, _ targetID: UUID, now: Date = Date(), calendar: Calendar = .current) throws {
        let immediate = validImmediateStudyTask(now: now, calendar: calendar)
        if let immediate,
           immediate.id == sourceID || immediate.id == targetID { throw ImmediateStudyError.pinnedTask }
        if let continuation = immediateStudyContinuation(now: now, calendar: calendar),
           let request = settings.immediateStudy,
           tasks.contains(where: {
               ($0.id == sourceID || $0.id == targetID) && $0.isUnconfirmed &&
               $0.courseID == request.task.courseID && $0.lessonID == continuation.id
           }) { throw ImmediateStudyError.pinnedTask }
        guard let source = tasks.first(where: { $0.id == sourceID }),
              let target = tasks.first(where: { $0.id == targetID }),
              source.isUnconfirmed, target.isUnconfirmed, sourceID != targetID,
              calendar.isDate(source.start, inSameDayAs: target.start),
              calendar.startOfDay(for: source.start) >= calendar.startOfDay(for: now) else {
            throw DailyTaskOrderError.unavailable
        }
        let day = calendar.startOfDay(for: source.start)
        let original = tasks.filter { $0.isUnconfirmed && calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
        guard let a = original.firstIndex(where: { $0.id == sourceID }),
              let b = original.firstIndex(where: { $0.id == targetID }) else {
            throw DailyTaskOrderError.unavailable
        }
        var keys = DailyTaskOrder.keys(for: original)
        keys.swapAt(a, b)
        var reordered = original
        reordered.swapAt(a, b)
        var context = self
        var hardReservations: [(start: Date, end: Date)] = []
        if let immediate, calendar.isDate(immediate.start, inSameDayAs: day) {
            // Other swaps must keep both the pinned slot and the floating-event
            // placement that makes it possible. Its history also reserves rest.
            reordered.removeAll { $0.id == immediate.id }
            let reservation = immediateStudyReservation(immediate, calendar: calendar)
            hardReservations.append((reservation.start, reservation.end))
            if let nominal = reservation.nominalEvent { context.fixedEvents.append(nominal) }
        }
        guard let placed = context.placeDailyTasks(reordered, earliest: original[0].start, calendar: calendar,
            floatingPlacements: nil, actualFloatingPlacements: nil, hardReservations: hardReservations) else {
            throw DailyTaskOrderError.noSpace
        }
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        tasks = tasks.map { byID[$0.id] ?? $0 }.sorted { $0.start < $1.start }
        var orders = settings.dailyTaskOrders ?? []
        orders.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        orders.append(.init(day: day, keys: keys))
        settings.dailyTaskOrders = orders
    }

    /// Packs whole lessons into available windows; never changes duration or another day.
    func placeDailyTasks(_ ordered: [ScheduledTask], earliest: Date, calendar: Calendar,
                         floatingPlacements: [UUID: Int]? = nil) -> [ScheduledTask]? {
        placeDailyTasks(ordered, earliest: earliest, calendar: calendar,
                        floatingPlacements: floatingPlacements, actualFloatingPlacements: nil, hardReservations: [])
    }

    private func placeDailyTasks(_ ordered: [ScheduledTask], earliest: Date, calendar: Calendar,
                                floatingPlacements: [UUID: Int]?,
                                actualFloatingPlacements: [UUID: (start: Date, end: Date)]?,
                                hardReservations: [(start: Date, end: Date)]) -> [ScheduledTask]? {
        guard !ordered.isEmpty else { return [] }
        // Whole tasks must fit the minute-indexed day before any placement arithmetic.
        guard ordered.allSatisfy({ (1...1440).contains($0.durationMinutes) }) else { return nil }
        let day = calendar.startOfDay(for: earliest)
        let engine = ScheduleEngine(calendar: calendar)
        let windows = settings.availability.filter { $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute }
        let study = Set(windows.flatMap { Array($0.startMinute..<$0.endMinute) })
        var available = study
        let events = fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        let floating = events.filter(\.isFloating)
        let moving = Set(ordered.map(\.id))
        let pause = TimeInterval(ScheduleEngine.breakMinutes * 60)
        let dayEnd = engine.instant(day: day, minute: 1440)
        // Adjacent days also reserve the rest interval across midnight.
        let obstacles = tasks.filter { !moving.contains($0.id) && ($0.isUnconfirmed || $0.completedMinutes > 0) }
            .map(\.retainedHistoryInterval)
            .filter { $0.end.addingTimeInterval(pause) > day && $0.start.addingTimeInterval(-pause) < dayEnd }
        func merged(_ spans: [(start: Date, end: Date)]) -> [(start: Date, end: Date)] {
            var result: [(start: Date, end: Date)] = []
            for span in spans.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
                if let last = result.last, span.start <= last.end {
                    result[result.count - 1].end = max(last.end, span.end)
                } else { result.append(span) }
            }
            return result
        }
        let exact = merged(events.filter { !$0.isFloating }.map {
            (start: engine.instant(day: day, minute: $0.startMinute), end: engine.instant(day: day, minute: $0.endMinute))
        } + hardReservations)
        var reservations: [UUID: (start: Date, end: Date)] = [:]
        if let actualFloatingPlacements {
            reservations = actualFloatingPlacements
            for event in events where !event.isFloating { available.subtract(event.startMinute..<event.endMinute) }
        } else {
            guard let placements = floatingPlacements ?? FloatingPlacement.reserve(events, studyMinutes: study) else { return nil }
            for event in events {
                let start = placements[event.id] ?? event.startMinute
                available.subtract(start..<(start + event.occupiedMinutes))
                if event.isFloating {
                    reservations[event.id] = (engine.instant(day: day, minute: start), engine.instant(day: day, minute: start + event.occupiedMinutes))
                }
            }
        }
        func retryWithActualWitness() -> [ScheduledTask]? {
            guard floatingPlacements == nil, actualFloatingPlacements == nil,
                  let alternate = jointDailyFloatingPlacements(ordered, earliest: earliest, day: day,
                      study: study, events: events, obstacles: obstacles, calendar: calendar) else { return nil }
            return placeDailyTasks(ordered, earliest: earliest, calendar: calendar,
                                   floatingPlacements: nil, actualFloatingPlacements: alternate, hardReservations: hardReservations)
        }
        let physicalOrder = (Array(reservations.values) + exact).sorted { $0.start < $1.start }
        let valid = reservations.count == floating.count && floating.allSatisfy { event in
            guard let span = reservations[event.id] else { return false }
            return span.end.timeIntervalSince(span.start) >= Double(event.occupiedMinutes) * 60
                && span.start >= engine.instant(day: day, minute: event.startMinute)
                && span.end <= engine.instant(day: day, minute: event.endMinute)
                && span.start >= day && span.end <= dayEnd
        } && zip(physicalOrder, physicalOrder.dropFirst()).allSatisfy { $0.end <= $1.start }
        guard valid else { return retryWithActualWitness() }
        // Date mapping can shorten or reorder clock-minute runs. Subtract actual
        // event spans from actual availability, including on the nominal fast path.
        var actualAvailable = merged(windows.map {
            (start: max(day, engine.instant(day: day, minute: $0.startMinute)),
             end: min(dayEnd, engine.instant(day: day, minute: $0.endMinute)))
        })
        for block in merged(exact + Array(reservations.values)) {
            actualAvailable = actualAvailable.flatMap { span -> [(start: Date, end: Date)] in
                guard block.start < span.end, block.end > span.start else { return [span] }
                var parts: [(start: Date, end: Date)] = []
                if span.start < block.start { parts.append((span.start, block.start)) }
                if block.end < span.end { parts.append((block.end, span.end)) }
                return parts
            }
        }
        var result: [ScheduledTask] = []
        var cursor = earliest
        for var task in ordered {
            var found = false
            // Earlier minutes cannot be candidates; avoid repeatedly constructing
            // hundreds of Calendar dates for each course in the same day.
            let firstMinute = calendar.isDate(cursor, inSameDayAs: day)
                ? calendar.component(.hour, from: cursor) * 60 + calendar.component(.minute, from: cursor)
                : 1440
            for minute in firstMinute..<1440 where available.contains(minute) {
                let start = engine.instant(day: day, minute: minute)
                let endMinute = minute + task.durationMinutes
                guard start >= cursor, endMinute <= 1440,
                      (minute..<endMinute).allSatisfy({ available.contains($0) }) else { continue }
                let end = start.addingTimeInterval(Double(task.durationMinutes * 60))
                guard actualAvailable.contains(where: { start >= $0.start && end <= $0.end }) else { continue }
                guard !obstacles.contains(where: { start < $0.end.addingTimeInterval(pause) && end > $0.start.addingTimeInterval(-pause) }) else { continue }
                task.start = start
                task.floatingWindowStart = nil
                task.floatingWindowEnd = nil
                let floating = events.filter { $0.isFloating && engine.instant(day: day, minute: $0.startMinute) < end && engine.instant(day: day, minute: $0.endMinute) > start }
                if !floating.isEmpty {
                    // Clip windows at exact appointments and availability boundaries.
                    var lower = minute, upper = endMinute
                    let regionStart = floating.map(\.startMinute).min()!
                    let regionEnd = floating.map(\.endMinute).max()!
                    let exact = events.filter { !$0.isFloating }
                    let study = Set(windows.flatMap { Array($0.startMinute..<$0.endMinute) })
                    func inWindow(_ m: Int) -> Bool { study.contains(m) && !exact.contains { m >= $0.startMinute && m < $0.endMinute } }
                    while lower > regionStart && inWindow(lower - 1) { lower -= 1 }
                    while upper < regionEnd && inWindow(upper) { upper += 1 }
                    task.floatingWindowStart = min(task.start, engine.instant(day: day, minute: lower))
                    task.floatingWindowEnd = max(task.end, engine.instant(day: day, minute: upper))
                }
                result.append(task)
                cursor = end.addingTimeInterval(pause)
                found = true
                break
            }
            if !found {
                return retryWithActualWitness()
            }
        }
        return result
    }

    /// A single queue preserves the requested order across courses. Only the event
    /// witness is reused; the existing placement path retains every original task.
    private func jointDailyFloatingPlacements(_ ordered: [ScheduledTask], earliest: Date, day: Date,
                                              study: Set<Int>, events: [FixedEvent], obstacles: [(start: Date, end: Date)],
                                              calendar: Calendar) -> [UUID: (start: Date, end: Date)]? {
        let floating = events.filter(\.isFloating)
        guard !floating.isEmpty, floating.count <= 8, ordered.count <= 600 else { return nil }
        let engine = ScheduleEngine(calendar: calendar)
        let boundaries = (0...1440).map { engine.instant(day: day, minute: $0) }
        let exact = events.filter { !$0.isFloating }
        let pause = TimeInterval(ScheduleEngine.breakMinutes * 60)
        var eventFree = [Bool](repeating: true, count: 1440)
        for minute in 0..<1440 {
            eventFree[minute] = !exact.contains { minute >= $0.startMinute && minute < $0.endMinute }
                && !obstacles.contains {
                    boundaries[minute] < $0.end.addingTimeInterval(pause)
                        && boundaries[minute + 1] > $0.start.addingTimeInterval(-pause)
                }
        }
        func windows(studyOnly: Bool) -> [ScheduleFeasibilitySearch.Window] {
            var result: [ScheduleFeasibilitySearch.Window] = [], start: Int?
            for minute in 0...1440 {
                let free = minute < 1440 && eventFree[minute] && (!studyOnly || study.contains(minute))
                if free, start == nil { start = minute }
                if !free, let first = start {
                    let lower = Int(ceil(boundaries[first].timeIntervalSinceReferenceDate / 60))
                    let upper = Int(floor(boundaries[minute].timeIntervalSinceReferenceDate / 60))
                    if lower < upper { result.append(.init(start: lower, end: upper)) }
                    start = nil
                }
            }
            return result
        }
        func minute(_ date: Date) -> Int { Int(ceil(date.timeIntervalSinceReferenceDate / 60)) }
        let queue = ScheduleFeasibilitySearch.Queue(courseID: ordered[0].courseID,
            start: minute(day), end: minute(boundaries[1440]), work: ordered.map {
                .init(minutes: $0.durationMinutes, lessonID: nil, lessonName: nil)
            })
        guard let solution = ScheduleFeasibilitySearch.find(queues: [queue], study: windows(studyOnly: true),
            eventWindows: windows(studyOnly: false), floating: floating.map {
                .init(key: day, start: minute(boundaries[$0.startMinute]), end: minute(boundaries[$0.endMinute]), minutes: $0.occupiedMinutes)
            }, floor: minute(earliest), initial: minute(day)),
              solution.tasks.count == ordered.count, solution.floatingStarts.count == floating.count else { return nil }
        var placements: [UUID: (start: Date, end: Date)] = [:]
        for (index, event) in floating.enumerated() {
            guard let start = solution.floatingStarts[index] else { return nil }
            placements[event.id] = (Date(timeIntervalSinceReferenceDate: Double(start) * 60),
                                    Date(timeIntervalSinceReferenceDate: Double(start + event.occupiedMinutes) * 60))
        }
        return placements
    }

    func applyingDailyTaskOrders(to generated: [ScheduledTask], calendar: Calendar) -> [ScheduledTask] {
        var result = generated
        for order in settings.dailyTaskOrders ?? [] {
            let indices = result.indices.filter { calendar.isDate(result[$0].start, inSameDayAs: order.day) }
            let original = indices.map { result[$0] }.sorted { $0.start < $1.start }
            guard let earliest = original.first?.start else { continue }
            let keys = DailyTaskOrder.keys(for: original)
            let ranks = Dictionary(order.keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let ordered = zip(keys, original).enumerated().sorted {
                (ranks[$0.element.0] ?? (order.keys.count + $0.offset)) < (ranks[$1.element.0] ?? (order.keys.count + $1.offset))
            }.map { $0.element.1 }
            // Generated tasks replace unfinished drafts. Retained history still reserves time.
            var context = self
            context.tasks.removeAll { $0.isUnconfirmed && $0.planningEnd > earliest }
            // Other generated days are not yet in saved state during replan.
            // Keep their current positions when applying this day's preference.
            let retainedIDs = Set(context.tasks.map(\.id))
            context.tasks += result.filter {
                !calendar.isDate($0.start, inSameDayAs: order.day) && !retainedIDs.contains($0.id)
            }
            guard let placed = context.placeDailyTasks(ordered, earliest: earliest, calendar: calendar) else { continue }
            for (i, task) in zip(indices, placed) { result[i] = task }
        }
        return result.sorted { $0.start < $1.start }
    }
}
