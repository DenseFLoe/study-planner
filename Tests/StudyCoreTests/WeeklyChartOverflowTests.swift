import XCTest
@testable import StudyCore

final class WeeklyChartOverflowTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return result
    }
    private var monday: Date { calendar.date(from: .init(year: 2026, month: 11, day: 2))! }
    private func state() -> PlannerState {
        var state = PlannerState()
        state.courses = [Course(name: "First", totalMinutes: 120, startDate: monday, deadline: monday + 86400),
                         Course(name: "Second", totalMinutes: 120, startDate: monday, deadline: monday + 86400)]
        return state
    }
    private func summary(_ state: PlannerState) -> WeeklyChartSeries.Summary {
        WeeklyChartSeries.summary(tasks: state.tasks, courses: state.courses, weekStart: monday, calendar: calendar)
    }
    func testAcceptedLegacyTasksCannotOverflowSameOrDifferentCourseTotals() throws {
        for secondCourse in [0, 1] {
            var state = state()
            state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: monday + 3600, durationMinutes: Int.max),
                           ScheduledTask(courseID: state.courses[secondCourse].id, start: monday + 7200, durationMinutes: 1)]
            let original = state; var ledger = SyncLedger(); try ledger.capture(state)
            let restored = try ledger.materialize()
            XCTAssertEqual(restored.tasks.count, 2)
            XCTAssertNil(summary(restored).totalMinutes); XCTAssertTrue(summary(restored).segments.isEmpty)
            XCTAssertEqual(state, original)
        }
    }
    func testWholeWeekTotalIsCheckedEvenWhenEverySegmentFits() {
        var state = state()
        state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: monday, durationMinutes: Int.max)]
        XCTAssertEqual(summary(state).totalMinutes, Int.max)
        XCTAssertEqual(summary(state).segments.first?.minutes, Int.max)
        state.tasks.append(ScheduledTask(courseID: state.courses[0].id, start: monday + 86400, durationMinutes: 1))
        XCTAssertNil(summary(state).totalMinutes); XCTAssertTrue(summary(state).segments.isEmpty)
    }
    func testEmptyNegativeAndOutOfWeekValuesStayExplicit() {
        var state = state()
        XCTAssertEqual(summary(state).totalMinutes, 0); XCTAssertTrue(summary(state).segments.isEmpty)
        state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: monday, durationMinutes: -1)]
        XCTAssertNil(summary(state).totalMinutes)
        state.tasks[0].start = monday - 86400
        XCTAssertEqual(summary(state).totalMinutes, 0)
    }
    func testCalendarWeeksIncludeBothDaylightSavingTransitions() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for components in [DateComponents(year: 2026, month: 3, day: 2), DateComponents(year: 2026, month: 10, day: 26)] {
            let start = try XCTUnwrap(calendar.date(from: components))
            let sunday = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: start))
            let lateSunday = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: sunday))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: start))
            let course = Course(name: "DST", totalMinutes: 120, startDate: start, deadline: end)
            let tasks = [ScheduledTask(courseID: course.id, start: lateSunday, durationMinutes: 30),
                         ScheduledTask(courseID: course.id, start: end, durationMinutes: 60)]
            let value = WeeklyChartSeries.summary(tasks: tasks, courses: [course], weekStart: start, calendar: calendar)
            XCTAssertEqual(value.totalMinutes, 30); XCTAssertEqual(value.segments.map(\.dayIndex), [6])
        }
    }
    func testReadOnlySnapshotKeepsFirstCourseMetadataWithoutIdentityTrap() {
        var state = state(); var duplicate = state.courses[0]; duplicate.name = "Later duplicate"; state.courses.append(duplicate)
        state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: monday, durationMinutes: 60)]
        let value = summary(state)
        XCTAssertEqual(value.segments.first?.courseName, "First")
        state.courses[0].name = "Changed"; state.tasks[0].durationMinutes = 90
        XCTAssertEqual(value.totalMinutes, 60); XCTAssertEqual(value.segments.first?.courseName, "First")
    }
}
