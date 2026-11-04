import XCTest
@testable import StudyCore

final class ConfirmationEditingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func fixture() -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "确认", totalMinutes: 180, startDate: now, deadline: now.addingTimeInterval(86400))
        state.courses = [course]
        state.tasks = [ScheduledTask(courseID: course.id, start: now, durationMinutes: 60)]
        return state
    }
    func testReloadReturnsLatestPendingTaskWithoutChangingStateOrRequiringAutomaticScheduling() throws {
        var state = fixture(); let id = state.tasks[0].id
        state.tasks[0].start += 86400; state.tasks[0].durationMinutes = 30
        state.tasks[0].lessonName = "Updated"; state.courses[0].autoScheduleEnabled = false
        let before = state, loaded = try state.pendingConfirmationTask(id: id)
        XCTAssertEqual(loaded, state.tasks[0]); XCTAssertEqual(state, before)
        try state.confirm(reviewed: loaded, actualMinutes: 20, now: now, studyDate: now - 86400)
        XCTAssertEqual(state.completions.first?.minutes, 20)
        let confirmed = state
        XCTAssertThrowsError(try state.pendingConfirmationTask(id: id))
        XCTAssertEqual(state, confirmed)
    }
    func testUnavailableCourseOrTaskCannotReloadOrAcceptConfirmation() throws {
        let original = fixture(), task = original.tasks[0]
        for missing in [0, 1, 2] {
            var state = original
            if missing == 0 { state.courses[0].isArchived = true }
            else if missing == 1 { state.courses = [] }
            else { state.tasks = [] }
            let before = state
            XCTAssertThrowsError(try state.pendingConfirmationTask(id: task.id))
            XCTAssertThrowsError(try state.confirm(taskID: task.id, actualMinutes: 20, now: now))
            XCTAssertThrowsError(try state.confirm(reviewed: task, actualMinutes: 20, now: now))
            XCTAssertEqual(state, before)
        }
    }
    func testChangedReviewedTaskCannotBeConfirmed() throws {
        let original = fixture(), task = original.tasks[0]
        let edits: [(inout ScheduledTask) -> Void] = [
            { $0.id = UUID() }, { $0.courseID = UUID() }, { $0.lessonID = "new" }, { $0.lessonName = "New" },
            { $0.start.addTimeInterval(60) }, { $0.durationMinutes += 1 },
            { $0.floatingWindowStart = self.now; $0.floatingWindowEnd = self.now.addingTimeInterval(7200) }
        ]
        for edit in edits {
            var changed = original; edit(&changed.tasks[0]); let before = changed
            XCTAssertThrowsError(try changed.confirm(reviewed: task, actualMinutes: 20, now: now))
            XCTAssertEqual(changed, before)
        }
        var state = original; state.courses[0].notes = "不影响任务的备注"
        try state.confirm(reviewed: task, actualMinutes: 20, now: now)
        XCTAssertEqual(state.completions.first?.minutes, 20)
        XCTAssertEqual(state.courses[0].notes, "不影响任务的备注")
        let confirmed = state.tasks[0]
        try state.undoConfirmation(reviewed: confirmed, now: now)
        try state.confirm(taskID: task.id, actualMinutes: 30, now: now.addingTimeInterval(60))
        let latest = state
        XCTAssertThrowsError(try state.undoConfirmation(reviewed: confirmed, now: now.addingTimeInterval(120)))
        XCTAssertEqual(state, latest)
    }
    func testStorageRejectsMovedTasksAndChangedCompletionRecordsAtomically() throws {
        let original = fixture(), task = original.tasks[0]
        var edited = original; try edited.confirm(reviewed: task, actualMinutes: 20, now: now)
        var moved = original; moved.tasks[0].start.addTimeInterval(60)
        var ledger = SyncLedger(); try ledger.capture(moved, now: now)
        let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence
        XCTAssertThrowsError(try ledger.captureChanges(from: original, to: edited, now: now.addingTimeInterval(120)))
        XCTAssertEqual(ledger.records, before); XCTAssertEqual(ledger.clock, clock); XCTAssertEqual(ledger.sequence, sequence)

        var undo = edited; try undo.undoConfirmation(reviewed: edited.tasks[0], now: now)
        var revised = edited; revised.completions[0].studyDate = now.addingTimeInterval(-86400)
        ledger = SyncLedger(); try ledger.capture(revised, now: now)
        let latest = ledger.records
        XCTAssertThrowsError(try ledger.captureChanges(from: edited, to: undo, now: now.addingTimeInterval(120)))
        XCTAssertEqual(ledger.records, latest)
    }
    func testStoragePreservesUnrelatedProgressAndAcceptsFreshUndoOfRecoveredHistory() throws {
        let original = fixture(), task = original.tasks[0]
        var edited = original; try edited.confirm(reviewed: task, actualMinutes: 20, now: now)
        var unrelated = original
        let other = ScheduledTask(courseID: task.courseID, start: now.addingTimeInterval(7200), durationMinutes: 60)
        unrelated.tasks.append(other)
        try unrelated.confirm(taskID: other.id, actualMinutes: 30, now: now)
        var ledger = SyncLedger(); try ledger.capture(unrelated, now: now)
        try ledger.captureChanges(from: original, to: edited, now: now.addingTimeInterval(60))
        let combined = try ledger.materialize()
        XCTAssertEqual(Set(combined.completions.map(\.taskID)), [task.id, other.id])
        XCTAssertEqual(combined.completions.reduce(0) { $0 + $1.minutes }, 50)

        // A stale replanner deleted a pending task before receiving its confirmation.
        let key = "tasks/" + task.id.uuidString
        var tombstone = ledger.records[key]!
        tombstone.payload = try JSONEncoder().encode(task); tombstone.deleted = true; ledger.records[key] = tombstone
        let recovered = try ledger.materialize()
        let history = try XCTUnwrap(recovered.tasks.first { $0.id == task.id })
        var undone = recovered; try undone.undoConfirmation(reviewed: history, now: now)
        try ledger.captureChanges(from: recovered, to: undone, now: now.addingTimeInterval(120))
        let saved = try ledger.materialize()
        XCTAssertFalse(saved.completions.contains { $0.taskID == task.id })
        XCTAssertEqual(saved.completions.first?.taskID, other.id)
    }
}
