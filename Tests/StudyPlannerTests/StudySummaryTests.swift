import XCTest
@testable import StudyCore
@testable import StudyPlanner

final class StudySummaryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testBackfillUsesActualStudyDayAndLeavesRecordsUntouched() {
        var state = PlannerState()
        state.completions = [.init(courseID: UUID(), taskID: UUID(), minutes: 45,
                                   recordedAt: date(4, 10), studyDate: date(3, 18))]
        let original = state
        XCTAssertEqual(ConfirmedStudySummary(state: state, day: date(3), calendar: calendar).minutes, 45)
        XCTAssertEqual(ConfirmedStudySummary(state: state, day: date(4), calendar: calendar).minutes, 0)
        XCTAssertEqual(state, original)
    }

    func testCrossMidnightConfirmationUsesLocalStudyDate() {
        var state = PlannerState()
        let task = ScheduledTask(courseID: UUID(), start: date(3, 23, 30), durationMinutes: 60)
        state.tasks = [task]
        state.completions = [.init(courseID: task.courseID, taskID: task.id, minutes: 60,
                                   recordedAt: date(4, 0, 30), studyDate: date(3))]
        XCTAssertEqual(ConfirmedStudySummary(state: state, day: date(3, 23, 59), calendar: calendar).minutes, 60)
        XCTAssertEqual(ConfirmedStudySummary(state: state, day: date(4, 0, 1), calendar: calendar).minutes, 0)
    }

    func testLegacySameDayIsCountedButAmbiguousAndOrphanRecordsAreNotGuessed() {
        var state = PlannerState()
        let sameDay = ScheduledTask(courseID: UUID(), start: date(3, 10), durationMinutes: 30)
        let overnight = ScheduledTask(courseID: UUID(), start: date(3, 23, 30), durationMinutes: 60)
        state.tasks = [sameDay, overnight]
        state.completions = [
            .init(courseID: sameDay.courseID, taskID: sameDay.id, minutes: 30, recordedAt: date(3, 11)),
            .init(courseID: overnight.courseID, taskID: overnight.id, minutes: 60, recordedAt: date(4, 0, 30)),
            .init(courseID: UUID(), taskID: UUID(), minutes: 20, recordedAt: date(4, 10))
        ]
        let original = state
        let yesterday = ConfirmedStudySummary(state: state, day: date(3), calendar: calendar)
        let today = ConfirmedStudySummary(state: state, day: date(4), calendar: calendar)
        XCTAssertEqual(yesterday.minutes, 30)
        XCTAssertEqual(yesterday.legacyRecordCount, 1)
        XCTAssertEqual(yesterday.ambiguousRecordCount, 1)
        XCTAssertEqual(today.minutes, 0)
        XCTAssertEqual(today.legacyRecordCount, 0)
        XCTAssertEqual(today.ambiguousRecordCount, 2)
        XCTAssertEqual(state, original)
    }

    func testLegacyDateUsesSuppliedTimeZoneRatherThanUTC() {
        var state = PlannerState()
        let task = ScheduledTask(courseID: UUID(), start: date(4, 7, 30), durationMinutes: 60)
        state.tasks = [task]
        // These timestamps cross UTC midnight but are the same local study day.
        state.completions = [.init(courseID: task.courseID, taskID: task.id, minutes: 60, recordedAt: date(4, 8, 30))]
        let summary = ConfirmedStudySummary(state: state, day: date(4), calendar: calendar)
        XCTAssertEqual(summary.minutes, 60)
        XCTAssertEqual(summary.legacyRecordCount, 1)
        XCTAssertEqual(summary.ambiguousRecordCount, 0)
    }

    func testOverflowIsExplicitAndDoesNotBecomeZeroOrWrap() {
        var state = PlannerState()
        state.completions = [Int.max, 1].map {
            .init(courseID: UUID(), taskID: UUID(), minutes: $0, recordedAt: date(4), studyDate: date(3))
        }
        let original = state
        let summary = ConfirmedStudySummary(state: state, day: date(3), calendar: calendar)
        XCTAssertNil(summary.minutes)
        XCTAssertEqual(summary.value, "合计超出范围")
        XCTAssertEqual(state, original)
        XCTAssertEqual(ConfirmedStudySummary(state: state, day: date(4), calendar: calendar).minutes, 0)
    }
}
