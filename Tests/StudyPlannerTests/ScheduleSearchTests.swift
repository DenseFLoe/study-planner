import XCTest
import StudyCore
@testable import StudyPlanner

final class ScheduleSearchTests: XCTestCase {
    func testSearchFindsLessonAcrossDatesAndCoursesInDateOrder() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let politics = Course(name: "政治强化", totalMinutes: 120, startDate: day, deadline: day)
        let math = Course(name: "高等数学", totalMinutes: 60, startDate: day, deadline: day)
        let first = ScheduledTask(courseID: politics.id, start: day, durationMinutes: 60, lessonName: "简单商品经济（上）")
        let second = ScheduledTask(courseID: politics.id, start: day.addingTimeInterval(86400), durationMinutes: 60, lessonName: "简单商品经济（下）")
        let unrelated = ScheduledTask(courseID: math.id, start: day, durationMinutes: 60, lessonName: "极限")
        let tasks = [second, unrelated, first]
        XCTAssertEqual(ScheduleSearch.matches(query: " 简单商品经济 \n", tasks: tasks, courses: [politics, math]).map(\.id), [first.id, second.id])
        XCTAssertEqual(ScheduleSearch.matches(query: "政治 上", tasks: tasks, courses: [politics, math]).map(\.id), [first.id])
        XCTAssertEqual(ScheduleSearch.matches(query: "高等数学", tasks: tasks, courses: [politics, math]).map(\.id), [unrelated.id])
        XCTAssertTrue(ScheduleSearch.matches(query: "不存在", tasks: tasks, courses: [politics, math]).isEmpty)
        XCTAssertTrue(ScheduleSearch.matches(query: " \n", tasks: tasks, courses: [politics, math]).isEmpty)
    }

    func testArchivedCourseMatchesOnlyVisibleHistory() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        var course = Course(name: "政治", totalMinutes: 120, startDate: day, deadline: day)
        course.isArchived = true
        let pending = ScheduledTask(courseID: course.id, start: day, durationMinutes: 60, lessonName: "简单商品经济")
        var confirmed = pending
        confirmed.id = UUID()
        confirmed.confirmedAt = day
        XCTAssertEqual(ScheduleSearch.matches(query: "简单商品经济", tasks: [pending, confirmed], courses: [course]).map(\.id), [confirmed.id])
    }

    func testConfirmationLabelReportsRecordedOutcomeInsteadOfBlanketConfirmed() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let courseID = UUID()

        var missed = ScheduledTask(courseID: courseID, start: day, durationMinutes: 60, lessonName: "极限")
        missed.status = .missed
        missed.confirmedAt = day.addingTimeInterval(3_600)
        XCTAssertEqual(ScheduleSearch.confirmationLabel(for: missed), "未完成 · 已重新排程 · 实际完成 0 h")

        var partial = ScheduledTask(courseID: courseID, start: day, durationMinutes: 120, lessonName: "极限")
        partial.status = .partial
        partial.completedMinutes = 60
        partial.confirmedAt = day.addingTimeInterval(3_600)
        XCTAssertEqual(ScheduleSearch.confirmationLabel(for: partial), "已完成 1 h · 余量已重排 · 实际完成 1 h")

        var completed = ScheduledTask(courseID: courseID, start: day, durationMinutes: 120, lessonName: "极限")
        completed.status = .completed
        completed.completedMinutes = 120
        completed.confirmedAt = day.addingTimeInterval(3_600)
        XCTAssertEqual(ScheduleSearch.confirmationLabel(for: completed), "已完成 · 实际完成 2 h")

        let planned = ScheduledTask(courseID: courseID, start: day, durationMinutes: 120, lessonName: "极限")
        XCTAssertEqual(ScheduleSearch.confirmationLabel(for: planned), "未确认 · 计划 2 h")

        var future = ScheduledTask(courseID: courseID, start: day.addingTimeInterval(86_400), durationMinutes: 180, lessonName: "极限")
        future.status = .future
        XCTAssertEqual(ScheduleSearch.confirmationLabel(for: future), "未确认 · 计划 3 h")
    }
}
