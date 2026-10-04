import XCTest
@testable import StudyCore

final class StudyLoadTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
    }
    func state(minutes: Int = 600) -> PlannerState {
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: minutes, startDate: date(14), deadline: date(18))]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 780) }
        return state
    }
    func assess(_ state: PlannerState) -> StudyLoadAssessment {
        StudyLoadAnalyzer(calendar: calendar).assess(state: state, now: date(14))!
    }
    func testThresholdsAndCountdowns() {
        let normal = assess(state())
        XCTAssertEqual(normal.level, .normal)
        XCTAssertEqual(normal.requiredDailyMinutes, 120)
        XCTAssertEqual(normal.criticalDailyMinutes, 300)
        XCTAssertEqual(normal.daysUntilWarning, 3)
        XCTAssertEqual(normal.daysUntilCritical, 4)
        XCTAssertEqual(assess(state(minutes: 1199)).level, .normal)
        XCTAssertEqual(assess(state(minutes: 1200)).level, .warning)
        XCTAssertEqual(assess(state(minutes: 1500)).level, .warning)
        let critical = assess(state(minutes: 1501))
        XCTAssertEqual(critical.level, .critical)
        XCTAssertEqual(critical.daysUntilCritical, 0)
    }
    func testNonDailyEventsDoNotChangeAnyEstimate() {
        var value = state()
        let baseline = assess(value)
        value.fixedEvents = [
            .init(title: "单次活动", startMinute: 480, endMinute: 780, startDate: date(14), endDate: date(14)),
            .init(title: "每周课程", startMinute: 480, endMinute: 780, startDate: date(14), endDate: date(18), weekdays: [2, 3, 4, 5, 6])
        ]
        let result = assess(value)
        XCTAssertEqual(result.availableMinutes, baseline.availableMinutes)
        XCTAssertEqual(result.daysUntilWarning, baseline.daysUntilWarning)
        XCTAssertEqual(result.daysUntilCritical, baseline.daysUntilCritical)
        XCTAssertTrue(ScheduleEngine(calendar: calendar).generate(state: value, now: date(14)).tasks.isEmpty)
    }
    func testDailyEventsAndOverlappingAvailabilityAreNotDoubleCounted() {
        var value = state()
        value.settings.availability += value.settings.availability
        let event = FixedEvent(title: "每日事项", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(18), weekdays: Set(1...7))
        value.fixedEvents = [event, event]
        XCTAssertEqual(assess(value).availableMinutes, 900)
        XCTAssertEqual(assess(value).daysUntilWarning, 1)
    }
    func testEarlierDeadlineCannotHideBehindLaterCourse() {
        var value = state(minutes: 301)
        value.courses[0].deadline = date(14)
        value.courses.append(.init(name: "英语", totalMinutes: 60, startDate: date(14), deadline: date(28)))
        let result = assess(value)
        XCTAssertEqual(result.level, .critical)
        XCTAssertEqual(result.deadline, date(14))
        XCTAssertEqual(result.requiredMinutes, 301)
    }
    func testFutureStartRestrictsCapacity() {
        var value = state(minutes: 601)
        value.courses[0].startDate = date(17)
        let result = assess(value)
        XCTAssertEqual(result.level, .critical)
        XCTAssertEqual(result.availableMinutes, 600)
        XCTAssertEqual(result.windowStart, date(17))
    }
    func testSharedDeadlineCombinesAllCoursesIncludingPaused() {
        var value = state(minutes: 700)
        var other = value.courses[0]
        other.id = UUID()
        other.autoScheduleEnabled = false
        value.courses.append(other)
        XCTAssertEqual(assess(value).requiredMinutes, 1400)
        XCTAssertEqual(assess(value).level, .warning)
    }
    func testCompletionArchiveOverdueAndNoAvailability() {
        var value = state()
        value.courses[0].initialCompletedMinutes = 600
        XCTAssertNil(StudyLoadAnalyzer(calendar: calendar).assess(state: value, now: date(14)))
        value.courses[0].initialCompletedMinutes = 300
        XCTAssertEqual(assess(value).requiredMinutes, 300)
        value.courses[0].deadline = date(13)
        XCTAssertEqual(assess(value).level, .critical)
        XCTAssertEqual(assess(value).availableMinutes, 0)
        value.courses[0].isArchived = true
        XCTAssertNil(StudyLoadAnalyzer(calendar: calendar).assess(state: value, now: date(14)))
        value = state()
        value.settings.availability = []
        XCTAssertEqual(assess(value).level, .critical)
        XCTAssertNil(assess(value).utilization)
    }
    func testDailyFloatingEventDeductsDurationRatherThanWholeWindow() {
        var value = state()
        var event = FixedEvent(title: "每日运动", startMinute: 480, endMinute: 780, startDate: date(14), endDate: date(18), weekdays: Set(1...7))
        event.floatingDurationMinutes = 60
        value.fixedEvents = [event]
        XCTAssertEqual(assess(value).availableMinutes, 1200)
        event.startMinute = 420 // Can fit entirely outside study hours.
        value.fixedEvents = [event]
        XCTAssertEqual(assess(value).availableMinutes, 1500)
    }
    func testUnevenWeekdayCapacityAndWholeDayCountdown() {
        var value = state(minutes: 480)
        value.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 780), .init(weekday: 6, startMinute: 480, endMinute: 780)]
        let result = assess(value)
        XCTAssertEqual(result.level, .warning)
        XCTAssertEqual(result.availableMinutes, 600)
        XCTAssertEqual(result.daysUntilCritical, 1)
        let evening = StudyLoadAnalyzer(calendar: calendar).assess(state: value, now: date(14).addingTimeInterval(22 * 3600))!
        XCTAssertEqual(evening.availableMinutes, result.availableMinutes)
    }

    func testCapacityCacheRespectsRuleDatesAndExcludedDays() {
        var value = state()
        value.courses[0].deadline = date(28)
        var event = FixedEvent(title: "每日事项", startMinute: 480, endMinute: 600,
                               startDate: date(15), endDate: date(23), weekdays: Set(1...7))
        event.excludedDates = [date(22)] // Same weekday as the previous week's active rule.
        value.fixedEvents = [event]
        XCTAssertEqual(assess(value).availableMinutes, 15 * 300 - 8 * 120)
    }

    func testLegacyExtremeDeadlineHasBoundedAnalysisAndExplicitRangeFlag() {
        var value = state()
        value.courses[0].deadline = calendar.date(from: DateComponents(year: 3000, month: 1, day: 1))!
        let result = assess(value)
        XCTAssertTrue(result.isHorizonLimited)
        XCTAssertEqual(result.deadline, calendar.date(byAdding: .year, value: 10, to: date(14)))
        XCTAssertLessThanOrEqual(result.days, 3661)
        XCTAssertFalse(assess(state()).isHorizonLimited)
    }
}
