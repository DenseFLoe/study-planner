import XCTest
@testable import StudyCore

final class FixedEventDuplicationTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: .init(year: year, month: month, day: day))!
    }
    func testOldRecurringEventBecomesIndependentDraftWithCalendarDaySpan() throws {
        let oldStart = date(2026, 3, 1), oldEnd = date(2026, 3, 15), today = date(2026, 11, 4)
        var original = FixedEvent(title: "课程", startMinute: 540, endMinute: 660, startDate: oldStart, endDate: oldEnd, weekdays: [2, 4])
        original.color = "green"; original.notes = "保留备注"; original.floatingDurationMinutes = 45
        original.excludedDates = [oldStart]
        let baseline = original
        var copy = try original.duplicate(startingOn: today, now: today, calendar: calendar)
        XCTAssertEqual(original, baseline)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.startDate, today); XCTAssertEqual(copy.endDate, date(2026, 11, 18))
        XCTAssertEqual(copy.weekdays, original.weekdays); XCTAssertEqual(copy.floatingDurationMinutes, 45)
        XCTAssertEqual(copy.startMinute, 540); XCTAssertEqual(copy.endMinute, 660)
        XCTAssertEqual(copy.title, original.title); XCTAssertEqual(copy.color, original.color); XCTAssertEqual(copy.notes, original.notes)
        XCTAssertTrue(copy.excludedDates.isEmpty)
        copy.notes = "只修改草稿"; XCTAssertEqual(original.notes, baseline.notes)
        XCTAssertNotEqual(copy.id, try original.duplicate(startingOn: today, now: today, calendar: calendar).id)
    }
    func testOneOffCopyStartsNoEarlierThanTodayAndUsesOneDate() throws {
        let today = date(2026, 11, 4), past = date(2025, 1, 1), future = date(2026, 12, 2)
        let event = FixedEvent(title: "单次", startMinute: 540, endMinute: 600, startDate: past, endDate: today)
        let copy = try event.duplicate(startingOn: past, now: today, calendar: calendar)
        XCTAssertEqual(copy.startDate, today); XCTAssertEqual(copy.endDate, today)
        let later = try event.duplicate(startingOn: future, now: today, calendar: calendar)
        XCTAssertEqual(later.startDate, future); XCTAssertEqual(later.endDate, future)
        XCTAssertTrue(later.weekdays.isEmpty)
    }
    func testCopiesRespectTenYearBoundAndRejectNonfiniteDates() throws {
        let today = date(2026, 11, 4), maximum = date(2036, 11, 4)
        let event = FixedEvent(title: "长期", startMinute: 540, endMinute: 600,
                               startDate: today, endDate: date(2036, 1, 1), weekdays: [2])
        let copy = try event.duplicate(startingOn: date(2036, 11, 3), now: today, calendar: calendar)
        XCTAssertEqual(copy.endDate, maximum)
        XCTAssertThrowsError(try event.duplicate(startingOn: date(2036, 11, 5), now: today, calendar: calendar))
        XCTAssertThrowsError(try event.duplicate(startingOn: Date(timeIntervalSinceReferenceDate: .infinity), now: today, calendar: calendar))
    }
    func testCopiedEventStillRequiresConflictReviewAndLeavesSourceUntouched() throws {
        let today = date(2026, 11, 4), tomorrow = date(2026, 11, 5)
        let source = FixedEvent(title: "原事项", startMinute: 540, endMinute: 600, startDate: tomorrow, endDate: tomorrow)
        var state = PlannerState(); state.fixedEvents = [source]
        let copy = try source.duplicate(startingOn: tomorrow, now: today, calendar: calendar)
        XCTAssertThrowsError(try FixedEventEdit(event: copy, baseline: nil).apply(to: &state, now: today, calendar: calendar)) {
            guard case PlannerError.fixedConflict = $0 else { return XCTFail("Expected conflict review: \($0)") }
        }
        XCTAssertEqual(state.fixedEvents, [source])
        var reviewed = copy; reviewed.startMinute = 660; reviewed.endMinute = 720
        try FixedEventEdit(event: reviewed, baseline: nil).apply(to: &state, now: today, calendar: calendar)
        XCTAssertEqual(state.fixedEvents.first { $0.id == source.id }, source)
        XCTAssertEqual(state.fixedEvents.first { $0.id == reviewed.id }, reviewed)
    }
}
