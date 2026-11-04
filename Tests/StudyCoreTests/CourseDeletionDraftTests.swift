import XCTest
@testable import StudyCore

final class CourseDeletionDraftTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func fixture() throws -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "课程", totalMinutes: 180, startDate: now, deadline: now.addingTimeInterval(86400))
        state.courses = [course]
        state.tasks = [.init(courseID: course.id, start: now, durationMinutes: 60),
                       .init(courseID: course.id, start: now.addingTimeInterval(7200), durationMinutes: 60)]
        try state.confirm(taskID: state.tasks[0].id, actualMinutes: 30, now: now)
        return state
    }
    func testChangedCourseOrHistoryRejectsDeletionWithoutPartialMutation() throws {
        let original = try fixture(), review = CourseDeletionDraft(reviewed: original.courses[0], state: original)
        let edits: [(inout PlannerState) throws -> Void] = [
            { $0.courses[0].name = "新名称" }, { $0.courses.removeAll() },
            { $0.completions[0].minutes += 1 }, { $0.completions[0].studyDate = self.now },
            { $0.tasks[0].start.addTimeInterval(60) }, { $0.completions.removeAll() },
            { try $0.confirm(taskID: $0.tasks[1].id, actualMinutes: 20, now: self.now) },
            { $0.completions.append(.init(courseID: original.courses[0].id, taskID: UUID(), minutes: 0, recordedAt: self.now)) }
        ]
        for edit in edits {
            var state = original; try edit(&state); let before = state
            XCTAssertThrowsError(try review.apply(to: &state)) { XCTAssertTrue($0 is CourseDeletionError) }
            XCTAssertEqual(state, before)
        }
    }
    func testReplannedPendingTasksAndUnrelatedChangesDoNotBlockReviewedDeletion() throws {
        let original = try fixture(), review = CourseDeletionDraft(reviewed: original.courses[0], state: original)
        var state = original
        state.tasks[1].id = UUID(); state.tasks[1].start.addTimeInterval(3600)
        state.tasks.reverse(); state.completions.reverse()
        var other = original.courses[0]; other.id = UUID(); other.name = "保留的课程"
        state.courses.append(other)
        let otherTask = ScheduledTask(courseID: other.id, start: now, durationMinutes: 45)
        state.tasks.append(otherTask)
        try state.confirm(taskID: otherTask.id, actualMinutes: 15, now: now)
        let otherHistory = state.tasks.filter { $0.courseID == other.id }
        let otherRecords = state.completions.filter { $0.courseID == other.id }
        state.settings.minimumScheduleUnit = 30
        try review.apply(to: &state)
        XCTAssertEqual(state.courses, [other]); XCTAssertEqual(state.tasks, otherHistory)
        XCTAssertEqual(state.completions, otherRecords)
        XCTAssertEqual(state.settings.minimumScheduleUnit, 30)
    }
    func testFreshReviewCanDeleteZeroMinuteOrphanHistoryButAnOldReviewCannot() throws {
        var state = try fixture()
        let stale = CourseDeletionDraft(reviewed: state.courses[0], state: state)
        state.completions.append(.init(courseID: state.courses[0].id, taskID: UUID(), minutes: 0, recordedAt: now))
        XCTAssertThrowsError(try stale.validate(in: state))
        let fresh = CourseDeletionDraft(reviewed: state.courses[0], state: state)
        try fresh.apply(to: &state)
        XCTAssertTrue(state.courses.isEmpty); XCTAssertTrue(state.tasks.isEmpty); XCTAssertTrue(state.completions.isEmpty)
    }
}
