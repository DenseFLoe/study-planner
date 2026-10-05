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
        let a = original.firstIndex { $0.id == sourceID }!
        let b = original.firstIndex { $0.id == targetID }!
        var keys = DailyTaskOrder.keys(for: original)
        keys.swapAt(a, b)
        var reordered = original
        reordered.swapAt(a, b)
        guard let placed = placeDailyTasks(reordered, earliest: original[0].start, calendar: calendar) else {
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
    func placeDailyTasks(_ ordered: [ScheduledTask], earliest: Date, calendar: Calendar) -> [ScheduledTask]? {
        guard !ordered.isEmpty else { return [] }
        let day = calendar.startOfDay(for: earliest)
        let engine = ScheduleEngine(calendar: calendar)
        let windows = settings.availability.filter { $0.weekday == calendar.component(.weekday, from: day) && $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute }
        var available = Set(windows.flatMap { Array($0.startMinute..<$0.endMinute) })
        let events = fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        guard let placements = FloatingPlacement.reserve(events, studyMinutes: available) else { return nil }
        for event in events {
            let start = placements[event.id] ?? event.startMinute
            available.subtract(start..<(start + event.occupiedMinutes))
        }
        let moving = Set(ordered.map(\.id))
        let pause = TimeInterval(ScheduleEngine.breakMinutes * 60)
        let obstacles = tasks.filter { !moving.contains($0.id) && calendar.isDate($0.start, inSameDayAs: day) && ($0.isUnconfirmed || $0.completedMinutes > 0) }
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
                guard !obstacles.contains(where: { start < $0.planningEnd.addingTimeInterval(pause) && end > $0.planningStart.addingTimeInterval(-pause) }) else { continue }
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
                    task.floatingWindowStart = engine.instant(day: day, minute: lower)
                    task.floatingWindowEnd = engine.instant(day: day, minute: upper)
                }
                result.append(task)
                cursor = end.addingTimeInterval(pause)
                found = true
                break
            }
            if !found { return nil }
        }
        return result
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
            guard let placed = context.placeDailyTasks(ordered, earliest: earliest, calendar: calendar) else { continue }
            for (i, task) in zip(indices, placed) { result[i] = task }
        }
        return result.sorted { $0.start < $1.start }
    }
}
