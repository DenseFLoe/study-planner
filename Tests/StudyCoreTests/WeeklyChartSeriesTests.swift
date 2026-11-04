import XCTest
import StudyCore

final class WeeklyChartSeriesTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day))!
    }
    private func course(_ name: String) -> Course {
        Course(name: name, totalMinutes: 600, startDate: date(1), deadline: date(30))
    }
    private func segment(_ day: Int, _ course: Course) -> WeeklyBarSegment {
        WeeklyBarSegment(dayIndex: day, dayLabel: "周\(day)", courseID: course.id,
                         courseName: course.name, minutes: 60)
    }

    /// The scale domain must cover every course, including beyond the old legend limit.
    func testDomainCoversEverySeriesBeyondTheLegendLimit() {
        let segments = (0..<6).map { segment($0, course("课程\($0)")) }
        let ids = WeeklyChartSeries.ids(in: segments)
        XCTAssertEqual(ids.count, 6)
        XCTAssertEqual(Set(ids), Set(segments.map(\.courseID)))
    }

    func testIDsAreUniqueAndKeepFirstAppearanceOrder() {
        let math = course("数学"), english = course("英语"), anotherMath = course("数学")
        let segments = [segment(0, math), segment(0, english), segment(1, math), segment(2, anotherMath)]
        XCTAssertEqual(WeeklyChartSeries.ids(in: segments), [math.id, english.id, anotherMath.id])
    }

    func testEmptySegmentsProduceEmptyDomain() {
        XCTAssertTrue(WeeklyChartSeries.ids(in: []).isEmpty)
    }

    func testSameNamedCoursesRemainSeparateAndRenamingKeepsIdentity() {
        let first = course("数学|基础")
        var second = course("数学|基础")
        let tasks = [ScheduledTask(courseID: first.id, start: date(2), durationMinutes: 60),
                     ScheduledTask(courseID: first.id, start: date(2).addingTimeInterval(7200), durationMinutes: 30),
                     ScheduledTask(courseID: second.id, start: date(2), durationMinutes: 120)]
        let segments = WeeklyChartSeries.segments(tasks: tasks, courses: [first, second], weekStart: date(2), calendar: calendar)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(Set(segments.map(\.id)).count, 2)
        XCTAssertEqual(segments.first { $0.courseID == first.id }?.minutes, 90)
        XCTAssertEqual(segments.first { $0.courseID == second.id }?.minutes, 120)
        second.name = "数学进阶"
        let renamed = WeeklyChartSeries.segments(tasks: tasks, courses: [first, second], weekStart: date(2), calendar: calendar)
        XCTAssertEqual(Set(segments.map(\.id)), Set(renamed.map(\.id)))
        XCTAssertEqual(renamed.first { $0.courseID == second.id }?.courseName, "数学进阶")
    }

    func testWeekBoundariesAndConfirmedTasksKeepOriginalPlan() {
        let course = course("化工原理")
        var confirmed = ScheduledTask(courseID: course.id, start: date(8).addingTimeInterval(23 * 3600), durationMinutes: 60)
        confirmed.status = .completed
        confirmed.completedMinutes = 30
        let tasks = [ScheduledTask(courseID: course.id, start: date(1), durationMinutes: 120),
                     ScheduledTask(courseID: course.id, start: date(2), durationMinutes: 90), confirmed,
                     ScheduledTask(courseID: course.id, start: date(9), durationMinutes: 120),
                     ScheduledTask(courseID: UUID(), start: date(3), durationMinutes: 60)]
        let segments = WeeklyChartSeries.segments(tasks: tasks, courses: [course], weekStart: date(2), calendar: calendar)
        XCTAssertEqual(segments.map(\.dayIndex), [0, 6])
        XCTAssertEqual(segments.map(\.minutes), [90, 60])
    }
}
