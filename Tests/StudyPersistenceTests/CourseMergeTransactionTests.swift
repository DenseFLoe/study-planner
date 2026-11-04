import XCTest
@testable import StudyCore
import StudyPersistence

final class CourseMergeTransactionTests: XCTestCase {
    @MainActor func testLateCompletionRejectsOldMergeThenFreshReviewPreservesLatestRows() async throws {
        let repository = try LocalRepository(inMemory: true), now = Date()
        var original = PlannerState()
        original.courses = ["来源 A", "来源 B", "其他课程"].map {
            Course(name: $0, totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
        }
        original.tasks = [.init(courseID: original.courses[0].id, start: now.addingTimeInterval(-3600), durationMinutes: 30)]
        let ids = Set(original.courses.prefix(2).map(\.id))
        let draft = try CourseMergeDraft(state: original, ids: ids, name: "合并")
        var latest = original
        try latest.confirm(taskID: original.tasks[0].id, actualMinutes: 20, now: now)
        latest.courses[2].notes = "同步的新备注"
        try repository.save(latest)
        let before = try repository.loadLedger().records
        let storage: PlannerRepository = repository
        do {
            _ = try await storage.mergeCoursesForInteraction(draft, from: original, now: now)
            XCTFail("Progress arriving after preview must invalidate the merge review")
        } catch { XCTAssertTrue(error is CourseMergeError) }
        XCTAssertEqual(try repository.loadLedger().records, before)
        let current = try repository.load()
        let fresh = try CourseMergeDraft(state: current, ids: ids, name: "合并")
        let saved = try await storage.mergeCoursesForInteraction(fresh, from: current, now: now)
        let merged = try XCTUnwrap(saved.courses.first { $0.name == "合并" })
        XCTAssertEqual(saved.courses.count, 2)
        XCTAssertEqual(saved.completions.map(\.minutes), [20])
        XCTAssertEqual(saved.completions.first?.courseID, merged.id)
        XCTAssertEqual(saved.courses.first { $0.id == original.courses[2].id }?.notes, "同步的新备注")
        XCTAssertEqual(try repository.loadLedger().materialize().completions, saved.completions)
    }
}
