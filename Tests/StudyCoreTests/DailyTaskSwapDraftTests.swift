import XCTest
@testable import StudyCore

final class DailyTaskSwapDraftTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 4))! }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = (0..<3).map { Course(name: "Course \($0)", totalMinutes: 120, startDate: day, deadline: day.addingTimeInterval(86400)) }
        state.tasks = state.courses.enumerated().map { ScheduledTask(courseID: $0.element.id, start: day.addingTimeInterval(Double(480 + $0.offset * 75) * 60), durationMinutes: 60) }
        return state
    }
    private func draft(_ state: PlannerState) throws -> DailyTaskSwapDraft {
        try .init(state: state, sourceID: state.tasks[0].id, targetID: state.tasks[2].id, now: day, calendar: calendar)
    }
    func testPreviewAndRepeatedSaveDoNotReverseAnAlreadyAppliedSwap() throws {
        let original = fixture(), edit = try draft(original)
        var expected = original
        try expected.swapDailyTasks(original.tasks[0].id, original.tasks[2].id, now: day, calendar: calendar)
        XCTAssertEqual(edit.preview, expected)
        try edit.apply(to: &expected, now: day)
        XCTAssertEqual(expected, edit.preview)
    }
    func testChangedTasksAndOrdersRejectWithoutMutation() throws {
        let original = fixture(), edit = try draft(original)
        let changes: [(inout PlannerState) -> Void] = [
            { $0.tasks[0].confirmedAt = self.day; $0.tasks[0].completedMinutes = 20; $0.tasks[0].status = .partial },
            { $0.tasks[0].durationMinutes += 15 },
            { $0.tasks[0].start += 60 },
            { $0.tasks[0].lessonID = "changed" },
            { $0.tasks.removeLast() },
            { var extra = $0.tasks[0]; extra.id = UUID(); $0.tasks.append(extra) },
            { $0.settings.dailyTaskOrders = [.init(day: self.day, keys: ["different order"])] }
        ]
        for change in changes {
            var latest = original; change(&latest); let before = latest
            XCTAssertThrowsError(try edit.apply(to: &latest, now: day)) { XCTAssertTrue($0 is DailyTaskSwapError) }
            XCTAssertEqual(latest, before)
        }
    }
    func testLateConfirmationKeepsHistoryOutOfPendingAssessment() throws {
        let original = fixture(), edit = try draft(original), confirmedID = original.tasks[0].id
        var latest = original
        try latest.confirm(taskID: confirmedID, actualMinutes: 20, now: day.addingTimeInterval(7 * 3600), calendar: calendar)
        let saved = latest
        XCTAssertThrowsError(try edit.apply(to: &latest, now: day)) { XCTAssertTrue($0 is DailyTaskSwapError) }
        let assessment = ScheduleEngine(calendar: calendar).assessSavedPlan(state: latest, now: day)
        XCTAssertEqual(latest, saved)
        XCTAssertEqual(latest.tasks.count, 3)
        XCTAssertEqual(latest.completions.map(\.minutes), [20])
        XCTAssertEqual(Set(assessment.tasks.map(\.id)), Set(original.tasks.dropFirst().map(\.id)))
        XCTAssertFalse(assessment.tasks.contains { $0.id == confirmedID })
    }
    func testUnrelatedChangesAndArrayOrderingArePreserved() throws {
        let original = fixture(), edit = try draft(original)
        var latest = original
        latest.tasks.reverse(); latest.courses[0].notes = "Remote notes"
        let tomorrow = day.addingTimeInterval(86400)
        let future = ScheduledTask(courseID: original.courses[0].id, start: tomorrow.addingTimeInterval(8 * 3600), durationMinutes: 60)
        latest.tasks.append(future); latest.settings.dailyTaskOrders = [.init(day: tomorrow, keys: ["future order"])]
        try edit.apply(to: &latest, now: day)
        XCTAssertEqual(latest.courses[0].notes, "Remote notes")
        XCTAssertEqual(latest.tasks.last, future)
        XCTAssertEqual(Array(latest.tasks.prefix(3)), edit.preview.tasks)
        XCTAssertEqual(latest.settings.dailyTaskOrders?.first?.keys, ["future order"])
    }
    func testCurrentConstraintsAndFinalSaveDayAreCheckedAtomically() throws {
        let original = fixture(), edit = try draft(original)
        var latest = original; latest.settings.availability = []
        let before = latest
        XCTAssertThrowsError(try edit.apply(to: &latest, now: day)) { XCTAssertTrue($0 is DailyTaskOrderError) }
        XCTAssertEqual(latest, before)
        for value in [original, edit.preview] {
            latest = value
            XCTAssertThrowsError(try edit.apply(to: &latest, now: day.addingTimeInterval(86400))) {
                guard case DailyTaskSwapError.pastDay = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertEqual(latest, value)
        }
    }
}
