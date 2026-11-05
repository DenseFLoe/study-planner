import XCTest
@testable import StudyCore

final class FixedOccurrenceRecoveryTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 5))! }
    private var tomorrow: Date { calendar.date(byAdding: .day, value: 1, to: day)! }
    private func fixture(floating: Bool = false) -> PlannerState {
        var state = PlannerState()
        var target = FixedEvent(title: "待恢复", startMinute: 540, endMinute: 660,
                                startDate: day.addingTimeInterval(-86400), endDate: tomorrow,
                                weekdays: Set(1...7), excludedDates: [day, tomorrow])
        if floating { target.floatingDurationMinutes = 90 }
        let blocker = FixedEvent(title: "占用", startMinute: 570, endMinute: 600,
                                 startDate: target.startDate, endDate: tomorrow, weekdays: Set(1...7))
        state.fixedEvents = [target, blocker]
        state.courses = [.init(name: "课程", totalMinutes: 120, startDate: target.startDate, deadline: tomorrow)]
        let task = ScheduledTask(courseID: state.courses[0].id, start: target.startDate, durationMinutes: 60)
        state.tasks = [task]
        try! state.confirm(taskID: task.id, actualMinutes: 45, now: target.startDate.addingTimeInterval(3600))
        return state
    }
    private func conflicts(_ state: PlannerState, file: StaticString = #filePath, line: UInt = #line) throws -> [FixedEventConflict] {
        var probe = state
        do {
            try FixedEventOccurrenceEdit(reviewed: state.fixedEvents[0], on: day, skipped: false)
                .apply(to: &probe, now: day, calendar: calendar)
        } catch let PlannerError.fixedConflict(found) { return found }
        XCTFail("Expected an occurrence restoration conflict", file: file, line: line)
        return []
    }

    func testReviewedRecoveryChangesOnlyTheSelectedDayAndKeepsLearningHistory() throws {
        for floating in [false, true] {
            var state = fixture(floating: floating)
            let original = state, reviewed = try conflicts(state)
            XCTAssertEqual(reviewed.count, 1)
            XCTAssertEqual(reviewed[0].reason, floating ? .floatingCapacity : .overlap)
            // Today's already-started recurrence must restore, not split tomorrow.
            let edit = FixedEventOccurrenceEdit(reviewed: state.fixedEvents[0], on: day.addingTimeInterval(3600),
                                                skipped: false, reviewedConflicts: reviewed)
            try edit.apply(to: &state, now: day.addingTimeInterval(10 * 3600), calendar: calendar)
            var expected = original
            expected.fixedEvents[0].excludedDates = [tomorrow]
            expected.fixedEvents[1].excludedDates = [day]
            XCTAssertEqual(state, expected)
            XCTAssertTrue(state.fixedEvents[0].occurs(on: day, calendar: calendar))
            XCTAssertTrue(state.fixedEvents[1].occurs(on: tomorrow, calendar: calendar))
            let result = state.replan(now: day, calendar: calendar)
            XCTAssertTrue(result.floatingIssues.isEmpty)
            XCTAssertEqual(state.completions, original.completions)
            XCTAssertTrue(state.tasks.contains(original.tasks[0]))
            XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 75)
        }
    }

    func testAllReviewedOccupantsAreSkippedTogetherAndUnrelatedEventsStay() throws {
        var state = fixture()
        var second = state.fixedEvents[1]; second.id = UUID(); second.title = "第二条"; second.startMinute = 620; second.endMinute = 640
        var unrelated = second; unrelated.id = UUID(); unrelated.startMinute = 780; unrelated.endMinute = 800
        state.fixedEvents += [second, unrelated]
        let reviewed = try conflicts(state)
        XCTAssertEqual(Set(reviewed.map(\.eventID)), Set([state.fixedEvents[1].id, second.id]))
        let target = state.fixedEvents[0]
        try FixedEventOccurrenceEdit(reviewed: target, on: day, skipped: false, reviewedConflicts: reviewed)
            .apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state.fixedEvents[1].excludedDates, [day])
        XCTAssertEqual(state.fixedEvents[2].excludedDates, [day])
        XCTAssertEqual(state.fixedEvents[3], unrelated)
    }

    func testChangedConflictRequiresNewReviewAndNeverPartiallySkips() throws {
        let original = fixture(), reviewed = try conflicts(original)
        let edit = FixedEventOccurrenceEdit(reviewed: original.fixedEvents[0], on: day, skipped: false, reviewedConflicts: reviewed)
        let changes: [(inout PlannerState) -> Void] = [
            { $0.fixedEvents[1].title = "另一端改名" },
            { $0.fixedEvents[1].startMinute += 5 },
            { $0.fixedEvents[1].floatingDurationMinutes = 20 },
            { value in var added = value.fixedEvents[1]; added.id = UUID(); value.fixedEvents.append(added) }
        ]
        for change in changes {
            var latest = original; change(&latest); let before = latest
            XCTAssertThrowsError(try edit.apply(to: &latest, now: day, calendar: calendar)) { error in
                guard case PlannerError.fixedConflict(let updated) = error else { return XCTFail("Expected refreshed conflicts") }
                XCTAssertNotEqual(updated, reviewed)
            }
            XCTAssertEqual(latest, before)
            let updated = try conflicts(latest)
            try FixedEventOccurrenceEdit(reviewed: original.fixedEvents[0], on: day, skipped: false, reviewedConflicts: updated)
                .apply(to: &latest, now: day, calendar: calendar)
            XCTAssertTrue(latest.fixedEvents[0].occurs(on: day, calendar: calendar))
        }
    }

    func testFreshNotesAndOtherExclusionsSurviveRecovery() throws {
        var state = fixture(), reviewed = try conflicts(state)
        let target = state.fixedEvents[0]
        state.fixedEvents[0].notes = "新备注"; state.fixedEvents[1].color = "blue"
        state.fixedEvents[1].excludedDates = [tomorrow]
        var expected = state
        expected.fixedEvents[0].excludedDates = [tomorrow]
        expected.fixedEvents[1].excludedDates = [day, tomorrow]
        try FixedEventOccurrenceEdit(reviewed: target, on: day, skipped: false, reviewedConflicts: reviewed)
            .apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state, expected)
    }

    func testDisappearedConflictDoesNotSkipItsMovedOccupant() throws {
        var state = fixture()
        let edit = FixedEventOccurrenceEdit(reviewed: state.fixedEvents[0], on: day, skipped: false, reviewedConflicts: try conflicts(state))
        state.fixedEvents[1].startMinute = 780; state.fixedEvents[1].endMinute = 840
        let occupant = state.fixedEvents[1]
        try edit.apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state.fixedEvents[1], occupant)
        XCTAssertEqual(state.fixedEvents[0].excludedDates, [tomorrow])
    }

    func testAlreadyRestoredOccurrenceDoesNotApplyOldSkipChoicesAgain() throws {
        var state = fixture()
        let edit = FixedEventOccurrenceEdit(reviewed: state.fixedEvents[0], on: day, skipped: false, reviewedConflicts: try conflicts(state))
        // Simulate a peer having restored it; retry is a no-op even if later
        // synchronization supplies an overlapping occupant.
        state.fixedEvents[0].excludedDates = [tomorrow]
        let before = state
        try edit.apply(to: &state, now: day, calendar: calendar)
        XCTAssertEqual(state, before)
    }

    func testStaleTargetPastDayAndMissingConsentNeverSkipOccupants() throws {
        let original = fixture(), reviewed = try conflicts(original)
        for scenario in 0..<5 {
            var state = original
            if scenario == 0 { state.fixedEvents[0].startMinute += 1 }
            if scenario == 1 { state.fixedEvents.removeFirst() }
            let before = state
            let edit = FixedEventOccurrenceEdit(reviewed: original.fixedEvents[0], on: day,
                skipped: scenario == 4, reviewedConflicts: scenario == 3 ? nil : reviewed)
            XCTAssertThrowsError(try edit.apply(to: &state, now: scenario == 2 ? tomorrow : day, calendar: calendar))
            XCTAssertEqual(state, before)
        }
    }
}
