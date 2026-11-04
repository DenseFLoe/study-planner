import XCTest
@testable import StudyCore

final class FixedEventNavigationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour))!
    }
    private func rule(_ start: Int = 2, _ end: Int = 16, weekdays: Set<Int> = [2, 4]) -> FixedEvent {
        .init(title: "课表", startMinute: 540, endMinute: 600, startDate: date(start), endDate: date(end), weekdays: weekdays)
    }
    func testUpcomingNavigationUsesTodayOrNextMatchingWeekday() {
        let event = rule()
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(1), calendar: calendar), date(2))
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(3), calendar: calendar), date(4))
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(4, 23), calendar: calendar), date(4))
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(5), calendar: calendar), date(9))
    }
    func testEndedRuleUsesLastMatchingDayInsteadOfCutoffDay() {
        let event = rule(2, 15)
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(16), calendar: calendar), date(11))
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(14), calendar: calendar), date(11))
    }
    func testSingleOccurrenceIgnoresLegacyLongEndDateAndKeepsSkippedDayReachable() {
        var event = rule(2, 30, weekdays: [])
        event.excludedDates = [date(2, 12)]
        let before = event
        for day in [1, 2, 3, 30] {
            XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(day), calendar: calendar), date(2))
        }
        XCTAssertEqual(event, before)
    }
    func testSkippedAndFloatingOccurrencesRemainReachable() {
        var event = rule()
        event.excludedDates = [date(4, 12)]; event.floatingDurationMinutes = 30
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: date(3), calendar: calendar), date(4))
        XCTAssertFalse(event.occurs(on: date(4), calendar: calendar))
        XCTAssertTrue(event.occurs(on: date(4), calendar: calendar, includingExcluded: true))
    }
    func testRulesWithNoValidOccurrenceDoNotInventDates() {
        XCTAssertNil(rule(3, 3).calendarNavigationDay(relativeTo: date(3), calendar: calendar))
        XCTAssertNil(rule(4, 2).calendarNavigationDay(relativeTo: date(3), calendar: calendar))
        XCTAssertNil(rule(2, 30, weekdays: [0, 8]).calendarNavigationDay(relativeTo: date(3), calendar: calendar))
    }
    func testDaylightSavingAndLargeRangesUseCalendarDays() {
        var cal = calendar; cal.timeZone = TimeZone(identifier: "America/New_York")!
        let first = cal.date(from: .init(year: 2026, month: 10, day: 31))!
        let sunday = cal.date(from: .init(year: 2026, month: 11, day: 1))!
        let monday = cal.date(from: .init(year: 2026, month: 11, day: 2))!
        let next = cal.date(from: .init(year: 2026, month: 11, day: 8))!
        let last = cal.date(from: .init(year: 2200, month: 11, day: 1))!
        let event = FixedEvent(title: "周日", startMinute: 540, endMinute: 600, startDate: first, endDate: last, weekdays: [1])
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: first, calendar: cal), sunday)
        XCTAssertEqual(event.calendarNavigationDay(relativeTo: monday, calendar: cal), next)
        let target = event.calendarNavigationDay(relativeTo: last + 86400, calendar: cal)
        XCTAssertNotNil(target); XCTAssertEqual(cal.component(.weekday, from: target!), 1)
        XCTAssertLessThanOrEqual(target!, last)
    }
}
