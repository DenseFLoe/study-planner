import XCTest
@testable import StudyCore

final class DailyReviewRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func task() -> ScheduledTask { ScheduledTask(courseID: UUID(), start: now - 86400, durationMinutes: 60) }

    func testUnchangedInputSurvivesWhileNewTasksRequireReview() {
        let first = task(), second = task(), added = task(), date = now - 2 * 86400
        let value = DailyReviewRefresh(previous: [first, second], latest: [second, added, first],
                                      values: [first.id: 20, second.id: 0], studyDates: [first.id: date], reviewed: [first.id, second.id])
        XCTAssertEqual(value.tasks, [second, added, first])
        XCTAssertEqual(value.values, [first.id: 20, second.id: 0]); XCTAssertEqual(value.studyDates, [first.id: date, second.id: second.start])
        XCTAssertEqual(value.reviewed, [first.id, second.id]); XCTAssertNil(value.values[added.id])
        XCTAssertTrue(value.changedIDs.isEmpty); XCTAssertEqual(value.addedCount, 1); XCTAssertEqual(value.removedCount, 0)
    }

    func testEveryTaskChangeInvalidatesReviewWithoutClampingInput() {
        let original = task(), date = now - 2 * 86400
        let edits: [(inout ScheduledTask) -> Void] = [
            { $0.courseID = UUID() }, { $0.start += 60 }, { $0.durationMinutes = 15 },
            { $0.lessonID = "lesson" }, { $0.lessonName = "New lesson" },
            { $0.floatingWindowStart = self.now - 86400; $0.floatingWindowEnd = self.now - 80000 }
        ]
        for edit in edits {
            var latest = original; edit(&latest)
            let value = DailyReviewRefresh(previous: [original], latest: [latest], values: [original.id: 30],
                                          studyDates: [original.id: date], reviewed: [original.id])
            XCTAssertEqual(value.values[original.id], 30); XCTAssertEqual(value.studyDates[original.id], date)
            XCTAssertEqual(value.tasks, [latest]); XCTAssertEqual(value.changedIDs, [original.id]); XCTAssertTrue(value.reviewed.isEmpty)
            XCTAssertEqual(value.addedCount, 0); XCTAssertEqual(value.removedCount, 0)
        }
    }

    func testConfirmedDeletedAndReplacedTasksCannotCarryOldDraftIntoSave() {
        let first = task(), deleted = task(), replacement = task()
        var confirmed = first; confirmed.confirmedAt = now; confirmed.completedMinutes = 20; confirmed.status = .partial
        let value = DailyReviewRefresh(previous: [first, deleted], latest: [confirmed, replacement],
                                      values: [first.id: 60, deleted.id: 30], studyDates: [first.id: now, deleted.id: now],
                                      reviewed: [first.id, deleted.id])
        XCTAssertEqual(value.tasks, [replacement]); XCTAssertTrue(value.values.isEmpty); XCTAssertTrue(value.studyDates.isEmpty)
        XCTAssertTrue(value.reviewed.isEmpty); XCTAssertEqual(value.addedCount, 1); XCTAssertEqual(value.removedCount, 2)
        XCTAssertTrue(value.changedIDs.isEmpty)
    }

    func testRepeatedRefreshNeverReinstatesReviewAndIsDetachedFromInputs() {
        let original = task(); var changed = original; changed.durationMinutes = 30
        var inputs = [original.id: 50]
        let first = DailyReviewRefresh(previous: [original], latest: [changed], values: inputs,
                                       studyDates: [original.id: now], reviewed: [original.id])
        let again = DailyReviewRefresh(previous: first.tasks, latest: first.tasks, values: first.values,
                                       studyDates: first.studyDates, reviewed: first.reviewed)
        XCTAssertEqual(again.values[original.id], 50); XCTAssertTrue(again.reviewed.isEmpty)
        XCTAssertTrue(again.changedIDs.isEmpty); XCTAssertEqual(again.addedCount, 0); XCTAssertEqual(again.removedCount, 0)
        inputs[original.id] = 0; changed.durationMinutes = 60
        XCTAssertEqual(first.values[original.id], 50); XCTAssertEqual(first.tasks[0].durationMinutes, 30)
    }

    func testUntouchedStudyDateRemainsThePreviouslyDisplayedDay() {
        let original = task(); var moved = original; moved.start = now - 3 * 86400
        let value = DailyReviewRefresh(previous: [original], latest: [moved], values: [original.id: 20],
                                      studyDates: [:], reviewed: [original.id], now: now)
        XCTAssertEqual(value.studyDates[original.id], original.start)
        XCTAssertTrue(value.reviewed.isEmpty)
        var future = original; future.start = now + 86400
        let futureValue = DailyReviewRefresh(previous: [future], latest: [future], values: [:],
                                            studyDates: [:], reviewed: [], now: now)
        XCTAssertEqual(futureValue.studyDates[future.id], now)
    }

    func testRefreshedTaskStillRequiresCurrentStateAtConfirmation() throws {
        var state = PlannerState(); let course = Course(name: "Review", totalMinutes: 120, startDate: now - 86400, deadline: now + 86400)
        state.courses = [course]; state.tasks = [ScheduledTask(courseID: course.id, start: now - 86400, durationMinutes: 60)]
        let original = state.tasks[0]
        let draft = DailyReviewRefresh(previous: [original], latest: [original], values: [original.id: 20],
                                       studyDates: [original.id: now - 86400], reviewed: [original.id])
        state.tasks[0].start += 60; let before = state
        XCTAssertThrowsError(try state.confirm(reviewed: draft.tasks[0], actualMinutes: draft.values[original.id]!, now: now,
                                              studyDate: draft.studyDates[original.id]))
        XCTAssertEqual(state, before)
        let empty = DailyReviewRefresh(previous: draft.tasks, latest: [], values: draft.values,
                                       studyDates: draft.studyDates, reviewed: draft.reviewed)
        XCTAssertTrue(empty.tasks.isEmpty); XCTAssertTrue(empty.reviewed.isEmpty); XCTAssertEqual(empty.removedCount, 1)
    }
}
