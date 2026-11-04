import XCTest
@testable import StudyCore

final class PlannerBackupRestoreTests: XCTestCase {
    private func fixture() -> PlannerState {
        let day = Calendar.current.startOfDay(for: Date())
        var state = PlannerState()
        state.courses = (0..<2).map { Course(name: "Course \($0)", totalMinutes: 120, startDate: day, deadline: day) }
        state.tasks = state.courses.enumerated().map { ScheduledTask(courseID: $0.element.id, start: day.addingTimeInterval(Double(480 + 75 * $0.offset) * 60), durationMinutes: 60) }
        state.fixedEvents = [.init(title: "Fixed", startMinute: 720, endMinute: 780, startDate: day, endDate: day)]
        return state
    }
    func testLateEditsRejectFullRestoreWithoutChangingAnyRows() throws {
        let original = fixture(), restore = PlannerBackupRestore(backup: .init(state: PlannerState(), reason: "Empty backup"), reviewedState: original)
        let edits: [(inout PlannerState) throws -> Void] = [
            { $0.courses[0].notes = "New notes" },
            { $0.courses.append(Course(name: "New course", totalMinutes: 60, startDate: Date(), deadline: Date())) },
            { try $0.confirm(taskID: $0.tasks[0].id, actualMinutes: 20, now: Date()) },
            { $0.fixedEvents[0].title = "New event title" },
            { $0.settings.minimumScheduleUnit = 30 },
            { $0.settings.availability[0].startMinute += 1 },
            { $0.settings.dailyTaskOrders = [.init(day: Date(), keys: ["new order"])] }
        ]
        for edit in edits {
            var latest = original; try edit(&latest); let before = latest
            XCTAssertThrowsError(try restore.apply(to: &latest)) { XCTAssertTrue($0 is PlannerBackupRestoreError) }
            XCTAssertEqual(latest, before)
        }
    }
    func testDisplayRowOrderingDoesNotBlockAnUnchangedReview() throws {
        let original = fixture(), replacement = PlannerState()
        let restore = PlannerBackupRestore(backup: .init(state: replacement, reason: "Reviewed"), reviewedState: original)
        var latest = original
        latest.courses.reverse(); latest.tasks.reverse(); latest.settings.availability.reverse()
        try restore.apply(to: &latest)
        XCTAssertEqual(latest, replacement)
    }
    func testInvalidBackupCannotPartiallyReplaceReviewedState() throws {
        let original = fixture()
        var backup = PlannerBackup(state: PlannerState(), reason: "Invalid"); backup.format = 99
        let restore = PlannerBackupRestore(backup: backup, reviewedState: original)
        var latest = original
        XCTAssertThrowsError(try restore.apply(to: &latest))
        XCTAssertEqual(latest, original)
    }
}
