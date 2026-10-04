import Foundation

/// A theoretical, divisible-minute budget. Non-daily events and minimum task
/// blocks remain the scheduler's responsibility, not this upper-limit estimate.
public struct StudyLoadAssessment: Sendable {
    public enum Level: Sendable { case normal, warning, critical }
    public var level: Level
    public var windowStart: Date
    public var deadline: Date
    public var requiredMinutes: Int
    public var availableMinutes: Int
    public var days: Int
    public var daysUntilWarning: Int?
    public var daysUntilCritical: Int?
    public var isHorizonLimited = false
    public var requiredDailyMinutes: Double { Double(requiredMinutes) / Double(days) }
    public var criticalDailyMinutes: Double { Double(availableMinutes) / Double(days) }
    public var utilization: Double? {
        availableMinutes > 0 ? Double(requiredMinutes) / Double(availableMinutes) : nil
    }
}

public struct StudyLoadAnalyzer: Sendable {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func assess(state: PlannerState, now: Date) -> StudyLoadAssessment? {
        let today = calendar.startOfDay(for: now)
        // Pausing automatic scheduling does not remove the course's deadline.
        let courses = state.courses.filter { !$0.isArchived && state.remainingMinutes(for: $0) > 0 }
        guard !courses.isEmpty else { return nil }
        struct Work {
            var start: Int
            var end: Int
            var minutes: Int
        }
        func offset(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        }
        let horizon = offset(calendar.date(byAdding: .year, value: 10, to: today)!)
        let work = courses.map { Work(start: max(0, min(horizon + 1, offset($0.startDate))), end: min(horizon, offset($0.deadline)), minutes: state.remainingMinutes(for: $0)) }
        let last = max(0, work.map(\.end).max() ?? 0)
        let dailyEvents = state.fixedEvents.filter {
            $0.weekdays.isSuperset(of: Set(1...7)) && $0.validDuration && $0.startMinute >= 0 && $0.endMinute <= 1440
        }
        var weeklyFree: [Int: [Bool]] = [:]
        for weekday in 1...7 {
            var free = [Bool](repeating: false, count: 1440)
            for window in state.settings.availability where window.weekday == weekday && window.startMinute >= 0 && window.endMinute <= 1440 && window.endMinute > window.startMinute {
                for minute in window.startMinute..<window.endMinute { free[minute] = true }
            }
            weeklyFree[weekday] = free
        }
        // Repeat capacity calculation only when weekday or active daily rules change.
        var capacities: [[Int]: Int] = [:]
        var prefix = [0]
        for index in 0...last {
            let day = calendar.date(byAdding: .day, value: index, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            let active = dailyEvents.indices.filter { dailyEvents[$0].occurs(on: day, calendar: calendar) }
            let key = [weekday] + active
            if let cached = capacities[key] {
                prefix.append(prefix.last! + cached)
                continue
            }
            var free = weeklyFree[weekday]!
            let events = active.map { dailyEvents[$0] }
            for event in events where !event.isFloating {
                for minute in event.startMinute..<event.endMinute { free[minute] = false }
            }
            // A floating event can use time outside study availability. Deduct only
            // its unavoidable overlap: this stays an optimistic upper bound even
            // when several floating windows cannot actually be packed together.
            var floatingCost = 0
            for event in events where event.isFloating {
                let outside = (event.startMinute..<event.endMinute).filter { !free[$0] }.count
                floatingCost += max(0, event.occupiedMinutes - outside)
            }
            let capacity = max(0, free.filter { $0 }.count - floatingCost)
            capacities[key] = capacity
            prefix.append(prefix.last! + capacity)
        }
        let ends = Array(Set(work.map(\.end))).sorted()
        func snapshot(skipping skipped: Int) -> StudyLoadAssessment {
            var worst: StudyLoadAssessment?
            let starts = Set([skipped] + work.map { max(skipped, $0.start) })
            for start in starts.sorted() {
                for end in ends {
                    // Include overdue work even though its remaining capacity is zero.
                    let required = work.filter { max(skipped, $0.start) >= start && $0.end <= end }.reduce(0) { $0 + $1.minutes }
                    guard required > 0 else { continue }
                    let capacity = end >= start && start <= last ? prefix[end + 1] - prefix[start] : 0
                    let level: StudyLoadAssessment.Level = required > capacity ? .critical : (Double(required) >= Double(capacity) * 0.8 ? .warning : .normal)
                    let candidate = StudyLoadAssessment(
                        level: level,
                        windowStart: calendar.date(byAdding: .day, value: start, to: today)!,
                        deadline: calendar.date(byAdding: .day, value: end, to: today)!,
                        requiredMinutes: required, availableMinutes: capacity, days: max(1, end - start + 1)
                    )
                    let ratio = candidate.utilization ?? .infinity
                    if worst == nil || ratio > (worst!.utilization ?? .infinity) { worst = candidate }
                }
            }
            return worst!
        }
        var result = snapshot(skipping: 0)
        result.isHorizonLimited = courses.contains { offset($0.deadline) > horizon }
        // With no additional completions, capacity only decreases as days are lost.
        func firstDay(reaching threshold: StudyLoadAssessment.Level) -> Int {
            func reached(_ level: StudyLoadAssessment.Level) -> Bool {
                threshold == .critical ? level == .critical : level != .normal
            }
            if reached(result.level) { return 0 }
            var low = 1, high = last + 1
            while low < high {
                let middle = low + (high - low) / 2
                if reached(snapshot(skipping: middle).level) { high = middle } else { low = middle + 1 }
            }
            return low
        }
        result.daysUntilWarning = firstDay(reaching: .warning)
        result.daysUntilCritical = firstDay(reaching: .critical)
        return result
    }
}
