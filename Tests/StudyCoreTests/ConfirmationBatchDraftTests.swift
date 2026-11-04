import XCTest
@testable import StudyCore

final class ConfirmationBatchDraftTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "Batch", totalMinutes: 180, startDate: now - 86400, deadline: now + 86400)
        state.courses = [course]
        state.tasks = [ScheduledTask(courseID: course.id, start: now - 86400, durationMinutes: 60),
                       ScheduledTask(courseID: course.id, start: now - 7200, durationMinutes: 60)]
        return state
    }
    private func draft(_ tasks: [ScheduledTask], minutes: [UUID: Int], dates: [UUID: Date] = [:]) throws -> ConfirmationBatchDraft {
        try ConfirmationBatchDraft(reviewed: tasks, minutes: minutes, studyDates: dates, now: now, calendar: calendar)
    }

    func testOnlySelectedRowsSaveAndUnselectedChangesDoNotBlockThem() throws {
        var state = fixture(); let selected = state.tasks[0], skipped = state.tasks[1]
        let review = try draft([selected], minutes: [selected.id: 20, skipped.id: -99], dates: [selected.id: now - 2 * 86400, skipped.id: now + 86400])
        state.tasks[1].durationMinutes = 30; let unselected = state.tasks[1]
        try review.apply(to: &state, now: now)
        XCTAssertEqual(review.count, 1); XCTAssertEqual(state.tasks[1], unselected)
        XCTAssertEqual(state.completions.map(\.taskID), [selected.id]); XCTAssertEqual(state.completions.map(\.minutes), [20])
        XCTAssertEqual(state.completions.first?.studyDate, calendar.startOfDay(for: now - 2 * 86400))
        XCTAssertTrue(state.tasks[1].isUnconfirmed)
    }

    func testDraftKeepsSubmittedValuesAndExplicitZeroSeparateFromUnselectedRows() throws {
        var state = fixture(); let task = state.tasks[0]
        var minutes = [task.id: 0], dates = [task.id: now - 86400]
        let review = try draft([task], minutes: minutes, dates: dates)
        minutes[task.id] = 60; dates[task.id] = now
        try review.apply(to: &state, now: now)
        XCTAssertEqual(state.tasks[0].status, .missed); XCTAssertEqual(state.completions.first?.minutes, 0)
        XCTAssertEqual(state.completions.first?.studyDate, calendar.startOfDay(for: now - 86400))
        XCTAssertTrue(state.tasks[1].isUnconfirmed)
    }

    func testSuccessfulPartialSaveRefreshesRemainingInputsForTheNextBatch() throws {
        var state = fixture()
        // Both rows must already be eligible for the batch review. Today's
        // ended tasks enter that list only after the configured reminder time.
        state.tasks[1].start = now - 86400 + 7200
        let original = state.tasks, first = original[0], second = original[1]
        XCTAssertEqual(state.confirmationCandidates(at: now, calendar: calendar), original)
        let minutes = [first.id: 20, second.id: 35], dates = [second.id: now - 2 * 86400]
        try draft([first], minutes: minutes, dates: dates).apply(to: &state, now: now)
        let remaining = DailyReviewRefresh(previous: original, latest: state.confirmationCandidates(at: now, calendar: calendar),
                                           values: minutes, studyDates: dates, reviewed: [first.id], now: now)
        XCTAssertEqual(remaining.tasks, [second]); XCTAssertEqual(remaining.values, [second.id: 35])
        XCTAssertEqual(remaining.studyDates, dates); XCTAssertTrue(remaining.reviewed.isEmpty)
        XCTAssertEqual(remaining.removedCount, 1)
        try draft(remaining.tasks, minutes: remaining.values, dates: remaining.studyDates).apply(to: &state, now: now)
        XCTAssertEqual(state.completions.map(\.minutes), [20, 35])
        XCTAssertTrue(state.confirmationCandidates(at: now, calendar: calendar).isEmpty)
    }

    func testIncompleteOrInvalidSelectionsCannotCreateDrafts() throws {
        let state = fixture(), task = state.tasks[0]
        XCTAssertThrowsError(try draft([], minutes: [:]))
        XCTAssertThrowsError(try draft([task, task], minutes: [task.id: 20]))
        XCTAssertThrowsError(try draft([task], minutes: [:]))
        for minutes in [-1, 61] { XCTAssertThrowsError(try draft([task], minutes: [task.id: minutes])) }
        XCTAssertThrowsError(try draft([task], minutes: [task.id: 20], dates: [task.id: now + 86400]))
        var confirmed = task; confirmed.confirmedAt = now; confirmed.status = .completed
        XCTAssertThrowsError(try draft([confirmed], minutes: [task.id: 20]))
    }

    func testAChangedSelectedRowPreventsEveryWriteAndRepeatedSaveCannotDoubleCredit() throws {
        let original = fixture(), first = original.tasks[0], second = original.tasks[1]
        let review = try draft(original.tasks, minutes: [first.id: 20, second.id: 30])
        var changed = original; changed.tasks[1].start += 60; let before = changed
        XCTAssertThrowsError(try review.apply(to: &changed, now: now)); XCTAssertEqual(changed, before)
        var state = original; try review.apply(to: &state, now: now)
        XCTAssertEqual(state.completions.map(\.minutes), [20, 30])
        let saved = state
        XCTAssertThrowsError(try review.apply(to: &state, now: now)); XCTAssertEqual(state, saved)
    }

    func testFailureDuringLaterCreditCalculationLeavesEarlierRowUnwritten() throws {
        var state = fixture(); var archived = state.courses[0]; archived.id = UUID(); archived.isArchived = true
        state.courses.append(archived); state.tasks[1].courseID = archived.id
        let review = try draft(state.tasks, minutes: Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, 20) }))
        let before = state
        XCTAssertThrowsError(try review.apply(to: &state, now: now)); XCTAssertEqual(state, before)
    }

    func testCurrentProgressLimitsCreditsInTheReviewedOrder() throws {
        var state = fixture()
        let review = try draft(state.tasks, minutes: Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, 60) }))
        state.courses[0].initialCompletedMinutes = 150
        try review.apply(to: &state, now: now)
        XCTAssertEqual(state.completions.map(\.minutes), [30, 0])
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 180)
    }

    func testReplanUsesCurrentTimeAndFloatingWindowEnd() throws {
        var task = fixture().tasks[0]; task.start = now + 3600
        let full = try draft([task], minutes: [task.id: 60])
        XCTAssertFalse(full.requiresReplan(at: now)); XCTAssertTrue(full.requiresReplan(at: task.end))
        XCTAssertTrue(try draft([task], minutes: [task.id: 20]).requiresReplan(at: now))
        task.floatingWindowStart = now; task.floatingWindowEnd = now + 10800
        let floating = try draft([task], minutes: [task.id: 60])
        XCTAssertFalse(floating.requiresReplan(at: now + 10799)); XCTAssertTrue(floating.requiresReplan(at: now + 10800))
    }
}
