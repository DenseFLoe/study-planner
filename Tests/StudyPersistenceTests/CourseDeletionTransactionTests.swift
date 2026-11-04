import XCTest
@testable import StudyCore
import StudyPersistence

final class CourseDeletionTransactionTests: XCTestCase {
    @MainActor func testLateProgressRejectsOldDeletionAndFreshReviewDeletesOnlyReviewedCourse() async throws {
        let repository = try LocalRepository(inMemory: true), now = Date()
        var original = PlannerState()
        original.courses = [.init(name: "删除前核对", totalMinutes: 60, startDate: now, deadline: now),
                            .init(name: "其他课程", totalMinutes: 60, startDate: now, deadline: now)]
        original.tasks = [.init(courseID: original.courses[0].id, start: now, durationMinutes: 60)]
        let review = CourseDeletionDraft(reviewed: original.courses[0], state: original)
        var latest = original
        try latest.confirm(taskID: original.tasks[0].id, actualMinutes: 20, now: now)
        latest.courses[1].notes = "后来编辑的备注"
        try repository.save(latest)
        let before = try repository.loadLedger().records
        let storage: PlannerRepository = repository
        do {
            _ = try await storage.deleteCourseForInteraction(review, from: original, now: now)
            XCTFail("New progress must invalidate an old deletion review")
        } catch { XCTAssertTrue(error is CourseDeletionError) }
        XCTAssertEqual(try repository.loadLedger().records, before)
        let current = try repository.load()
        XCTAssertEqual(current.completions, latest.completions)
        let fresh = CourseDeletionDraft(reviewed: original.courses[0], state: current)
        let saved = try await storage.deleteCourseForInteraction(fresh, from: current, now: now)
        XCTAssertEqual(saved.courses, [latest.courses[1]])
        XCTAssertTrue(saved.completions.isEmpty)
        XCTAssertFalse(saved.tasks.contains { $0.courseID == original.courses[0].id })
        XCTAssertEqual(try repository.loadLedger().materialize().courses, saved.courses)
    }
}
