import Foundation

extension FixedEvent {
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
