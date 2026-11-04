import XCTest
import StudyCore
@testable import StudyPlanner

final class ScheduleSearchTests: XCTestCase {
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
