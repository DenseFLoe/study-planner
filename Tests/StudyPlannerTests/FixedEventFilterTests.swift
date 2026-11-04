import XCTest
import StudyCore
@testable import StudyPlanner

final class FixedEventFilterTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var monday: Date { calendar.date(from: .init(year: 2026, month: 11, day: 2))! }
    private func event(weekdays: Set<Int>) -> FixedEvent {
        FixedEvent(title: "学校 · 化工原理 实验", startMinute: 540, endMinute: 600,
                   startDate: monday, endDate: monday.addingTimeInterval(14 * 86400), weekdays: weekdays)
    }

    func testNameTermsAndRecurringWeekdayAreCombined() {
        let value = event(weekdays: [2, 4])
        XCTAssertTrue(FixedEventFilter.matches(value, query: " 化工  实验\n", weekday: 2, calendar: calendar))
        XCTAssertFalse(FixedEventFilter.matches(value, query: "化工", weekday: 3, calendar: calendar))
        XCTAssertFalse(FixedEventFilter.matches(value, query: "数学", weekday: 2, calendar: calendar))
        XCTAssertTrue(FixedEventFilter.matches(value, query: "\n ", weekday: 0, calendar: calendar))
    }

    func testSingleEventUsesLocalOccurrenceDayRatherThanEndDate() {
        let value = event(weekdays: [])
        XCTAssertTrue(FixedEventFilter.matches(value, query: "", weekday: 2, calendar: calendar))
        XCTAssertFalse(FixedEventFilter.matches(value, query: "", weekday: 1, calendar: calendar))
    }

    func testTemporarilySkippedRuleIsStillSearchableWithoutChanges() {
        var value = event(weekdays: [2])
        value.excludedDates = [monday]
        let original = value
        XCTAssertTrue(FixedEventFilter.matches(value, query: "实验", weekday: 2, calendar: calendar))
        XCTAssertEqual(value, original)
    }
}
