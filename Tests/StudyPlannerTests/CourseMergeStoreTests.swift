import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class CourseMergeStoreTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var current: PlannerState
        var incoming: PlannerState?
        var mergeCalls = 0, writes = 0
        init(_ state: PlannerState) { current = state }
        func load() throws -> PlannerState { current }
        func save(_ state: PlannerState) throws { current = state; writes += 1 }
        @MainActor func mergeCoursesForInteraction(_ draft: CourseMergeDraft,
                                                   from baseline: PlannerState, now: Date) async throws -> PlannerState {
            mergeCalls += 1
            if let incoming { current = incoming; self.incoming = nil }
            var next = current
            try draft.apply(to: &next)
            next.removeArchivedCourses(); _ = next.replan(now: now)
            try save(next)
            return next
        }
    }

    @MainActor func testLateProgressRefreshesStoreWithoutMergingAndAllowsReviewedRetry() async throws {
        let now = Date()
        var original = PlannerState()
        original.courses = ["来源 A", "来源 B"].map { Course(name: $0, totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400)) }
        original.tasks = [.init(courseID: original.courses[0].id, start: now.addingTimeInterval(-3600), durationMinutes: 30)]
        let ids = Set(original.courses.map(\.id))
        let review = try CourseMergeDraft(state: original, ids: ids, name: "合并名称保留")
        var incoming = original
        try incoming.confirm(taskID: original.tasks[0].id, actualMinutes: 20, now: now)
        let repository = Repository(original); repository.incoming = incoming
        let store = PlannerStore(state: original, repository: repository, result: ScheduleEngine().assessSavedPlan(state: original, now: now))
        let rejected = await store.mergeCourses(review, now: now)
        XCTAssertFalse(rejected)
        XCTAssertEqual(repository.mergeCalls, 1); XCTAssertEqual(repository.writes, 0)
        XCTAssertEqual(store.state, incoming); XCTAssertEqual(repository.current, incoming)
        XCTAssertTrue(store.errorMessage?.contains("未执行合并") == true)
        XCTAssertFalse(store.orderSaveBusy)
        let fresh = try CourseMergeDraft(state: store.state, ids: review.ids, name: review.name)
        let saved = await store.mergeCourses(fresh, now: now)
        XCTAssertTrue(saved); XCTAssertEqual(repository.mergeCalls, 2)
        XCTAssertEqual(store.state.courses.count, 1)
        XCTAssertEqual(store.state.courses.first?.name, review.name)
        XCTAssertEqual(store.state.completions.map(\.minutes), [20])
        XCTAssertEqual(store.state.completions.first?.courseID, store.state.courses.first?.id)
        XCTAssertEqual(repository.current, store.state)
        XCTAssertFalse(store.orderSaveBusy); XCTAssertNil(store.errorMessage)
    }
}
