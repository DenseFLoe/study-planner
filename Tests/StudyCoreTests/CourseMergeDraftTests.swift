import XCTest
@testable import StudyCore

final class CourseMergeDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_400)
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = ["来源 A", "来源 B", "其他课程"].map {
            Course(name: $0, totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
        }
        state.tasks = [.init(courseID: state.courses[0].id, start: now.addingTimeInterval(-3600), durationMinutes: 30)]
        return state
    }
    private func draft(_ state: PlannerState) throws -> CourseMergeDraft {
        try .init(state: state, ids: Set(state.courses.prefix(2).map(\.id)), name: " 合并复习 ")
    }
    func testLatestPendingPlansAndUnrelatedEditsArePreserved() throws {
        let original = fixture(), review = try draft(original)
        var latest = original
        latest.courses[2].notes = "另一端新备注"
        latest.tasks[0].start.addTimeInterval(600)
        latest.courses.reverse()
        let merged = try review.apply(to: &latest)
        XCTAssertEqual(merged.name, "合并复习")
        XCTAssertEqual(merged.totalMinutes, 120)
        XCTAssertEqual(latest.tasks[0].start, original.tasks[0].start.addingTimeInterval(600))
        XCTAssertEqual(latest.tasks[0].courseID, merged.id)
        XCTAssertEqual(latest.courses.first { $0.id == original.courses[2].id }?.notes, "另一端新备注")
        XCTAssertEqual(original.courses.count, 3)
    }
    func testLateProgressRejectsWithoutMutatingAndFreshReviewRetainsCredit() throws {
        let original = fixture(), review = try draft(original)
        for minutes in [0, 20, 30] {
            var latest = original
            try latest.confirm(taskID: original.tasks[0].id, actualMinutes: minutes, now: now)
            let before = latest
            XCTAssertThrowsError(try review.apply(to: &latest)) { XCTAssertTrue($0 is CourseMergeError) }
            XCTAssertEqual(latest, before)
            let fresh = try draft(latest), merged = try fresh.apply(to: &latest)
            XCTAssertEqual(latest.completions.map(\.minutes), [minutes])
            XCTAssertEqual(latest.completions.first?.courseID, merged.id)
            XCTAssertEqual(latest.completedMinutes(for: merged), minutes)
        }
    }
    func testChangedOrRemovedSourceRejectsAndArrayOrderDoesNot() throws {
        let original = fixture(), review = try draft(original)
        for action in 0..<4 {
            var latest = original
            switch action {
            case 0: latest.courses[0].deadline.addTimeInterval(86400)
            case 1: latest.courses[0].name = "新课名"
            case 2: latest.courses[0].isArchived = true
            default: latest.courses.removeFirst()
            }
            let before = latest
            XCTAssertThrowsError(try review.apply(to: &latest)) { XCTAssertTrue($0 is CourseMergeError) }
            XCTAssertEqual(latest, before)
        }
        var reordered = original; reordered.courses.reverse(); reordered.tasks.reverse()
        XCTAssertNoThrow(try review.apply(to: &reordered))
    }
    func testExistingCreditCorrectionInvalidatesPreviewAndSelectionMustBeValid() throws {
        var original = fixture()
        try original.confirm(taskID: original.tasks[0].id, actualMinutes: 20, now: now)
        let review = try draft(original)
        var latest = original; latest.completions[0].minutes = 25
        let before = latest
        XCTAssertThrowsError(try review.apply(to: &latest)) { XCTAssertTrue($0 is CourseMergeError) }
        XCTAssertEqual(latest, before)
        XCTAssertThrowsError(try CourseMergeDraft(state: original, ids: [original.courses[0].id], name: "合并"))
        XCTAssertThrowsError(try CourseMergeDraft(state: original, ids: Set(original.courses.prefix(2).map(\.id)), name: "  "))
    }
}
