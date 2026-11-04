import Foundation

extension FixedEvent {
    /// Locate a rule in the calendar, including temporarily skipped occurrences
    /// so their restore controls remain reachable. Prefer today or the next rule
    /// day, falling back to the last occurrence when the rule has ended.
    public func calendarNavigationDay(relativeTo reference: Date, calendar: Calendar = .current) -> Date? {
        let first = calendar.startOfDay(for: startDate)
        let last = calendar.startOfDay(for: weekdays.isEmpty ? min(startDate, endDate) : endDate)
        guard first <= last else { return nil }
        let anchor = min(max(calendar.startOfDay(for: reference), first), last)
        for offset in 0..<7 {
            guard let candidate = calendar.date(byAdding: .day, value: offset, to: anchor), candidate <= last else { break }
            if occurs(on: candidate, calendar: calendar, includingExcluded: true) { return candidate }
        }
        for offset in 1...6 {
            guard let candidate = calendar.date(byAdding: .day, value: -offset, to: anchor), candidate >= first else { break }
            if occurs(on: candidate, calendar: calendar, includingExcluded: true) { return candidate }
        }
        return nil
    }

    /// A rule ends with its last scheduled occurrence, including floating windows.
    /// Temporary skips remain restorable and do not end a rule early.
    public func hasEnded(at now: Date, calendar: Calendar = .current) -> Bool {
        let firstDay = calendar.startOfDay(for: startDate)
        var lastDay = calendar.startOfDay(for: endDate)
        if weekdays.isEmpty {
            lastDay = min(firstDay, lastDay)
        } else {
            // The last matching weekday is at most six days before the end date.
            for _ in 0..<7 {
                if weekdays.contains(calendar.component(.weekday, from: lastDay)) { break }
                lastDay = calendar.date(byAdding: .day, value: -1, to: lastDay)!
            }
        }
        guard lastDay >= firstDay,
              occurs(on: lastDay, calendar: calendar, includingExcluded: true) else { return true }
        return ScheduleEngine(calendar: calendar).instant(day: lastDay, minute: endMinute) <= now
    }
}
