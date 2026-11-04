import Foundation
import StudyCore

enum FixedEventFilter {
    /// Filter the saved rule, including temporarily skipped occurrences. A one-off
    /// event uses its occurrence date; a recurring event uses its weekday rule.
    static func matches(_ event: FixedEvent, query: String, weekday: Int, calendar: Calendar = .current) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard terms.allSatisfy({ event.title.localizedStandardContains(String($0)) }) else { return false }
        guard weekday != 0 else { return true }
        return event.weekdays.isEmpty
            ? calendar.component(.weekday, from: event.startDate) == weekday
            : event.weekdays.contains(weekday)
    }
}
