import Foundation

public enum FixedEventFilter {
    /// Filter the saved rule, including temporarily skipped occurrences. A one-off
    /// event uses its occurrence date; a recurring event uses its weekday rule.
    public static func matches(_ event: FixedEvent, query: String, weekday: Int, calendar: Calendar = .current) -> Bool {
        Query(query, weekday: weekday, calendar: calendar).matches(event)
    }

    /// One formatter per query; filtering preserves source order and never changes rules.
    public static func matching(_ events: [FixedEvent], query: String, weekday: Int, calendar: Calendar = .current) -> [FixedEvent] {
        let filter = Query(query, weekday: weekday, calendar: calendar)
        return events.filter { filter.matches($0) }
    }

    private struct Query {
        let terms: [String], weekday: Int, calendar: Calendar
        let dates: DateFormatter
        init(_ query: String, weekday: Int, calendar: Calendar) {
            terms = query.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace).map(String.init)
            self.weekday = weekday; self.calendar = calendar
            dates = DateFormatter(); dates.locale = Locale(identifier: "en_US_POSIX")
            dates.calendar = Calendar(identifier: .gregorian); dates.timeZone = calendar.timeZone
            dates.dateFormat = "yyyy-MM-dd"
        }
        func matches(_ event: FixedEvent) -> Bool {
            if weekday != 0 {
                let occurs = event.weekdays.isEmpty ? calendar.component(.weekday, from: event.startDate) == weekday : event.weekdays.contains(weekday)
                guard occurs else { return false }
            }
            guard !terms.isEmpty else { return true }
            let end = event.weekdays.isEmpty ? event.startDate : event.endDate
            let text = [event.title, event.notes, dates.string(from: event.startDate), dates.string(from: end)]
                .joined(separator: " ").precomposedStringWithCompatibilityMapping
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }
}
