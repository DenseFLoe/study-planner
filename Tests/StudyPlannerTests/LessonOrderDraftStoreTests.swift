import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class LessonOrderDraftStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Deterministically inject a peer write after background preparation and
    /// before the real repository transaction, without touching user databases.
    private final class Repository: PlannerRepository {
        let local: LocalRepository
        @MainActor var beforeOrderSave: (() throws -> Void)?
        init(_ state: PlannerState) throws {
            local = try LocalRepository(inMemory: true)
            try local.save(state)
        }
        func load() throws -> PlannerState { try local.load() }
        func save(_ state: PlannerState) throws { try local.save(state) }
        @MainActor func saveLessonOrderForInteraction(_ draft: LessonOrderDraft,
                                                     from baseline: PlannerState, now: Date) async throws -> PlannerState {
            try beforeOrderSave?()
            return try await local.saveLessonOrderForInteraction(draft, from: baseline, now: now)
        }
    }

    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = []
        var course = Course(name: "排序课程", totalMinutes: 180, startDate: now,
                            deadline: now.addingTimeInterval(86400 * 10))
        course.type = .lessonBasedRecorded
        course.manualLessons = ["a", "b", "c"].map { .init(id: $0, name: $0, durationMinutes: 60) }
        course.lessonOrder = ["a", "b", "c"]
        state.courses = [course]
        return state
    }
    @MainActor private func store(_ state: PlannerState, _ repository: any PlannerRepository) -> PlannerStore {
        PlannerStore(state: state, repository: repository,
                     result: ScheduleEngine().assessSavedPlan(state: state, now: now),
                     backups: PlannerBackupRepository(inMemory: true))
    }

    @MainActor func testVisibleRemoteOrderRejectsSaveAndKeepsDraft() async throws {
        let initial = fixture(), repository = try LocalRepository(inMemory: true)
        try repository.save(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        let remoteSaved = await store.change(now: now) { $0.courses[0].lessonOrder = ["c", "a", "b"] }
        XCTAssertTrue(remoteSaved)
        let latest = store.state, records = try repository.loadLedger().records
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, latest)
        XCTAssertEqual(try repository.load(), latest)
        XCTAssertEqual(try repository.loadLedger().records, records)
        XCTAssertEqual(draft.order, ["b", "a", "c"])
        XCTAssertTrue(draft.hasChanges)
        XCTAssertTrue(store.errorMessage?.contains("课节顺序") == true)
        XCTAssertFalse(store.orderSaveBusy)
    }

    @MainActor func testLateRemoteOrderRejectsAndRefreshesUIForExplicitReload() async throws {
        let initial = fixture(), repository = try Repository(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var remote = initial
        remote.courses[0].lessonOrder = ["c", "a", "b"]
        repository.beforeOrderSave = { try repository.local.save(remote) }
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, remote)
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.local.loadLedger().materialize(), remote)
        XCTAssertEqual(draft.order, ["b", "a", "c"])
        let reloaded = LessonOrderDraft(course: try XCTUnwrap(store.course(draft.course.id)), state: store.state)
        XCTAssertEqual(reloaded.order, ["c", "a", "b"])
        XCTAssertFalse(reloaded.hasChanges)
    }

    @MainActor func testLateConfirmationBlocksPendingDeletionAndPreservesAllRows() async throws {
        let initial = fixture(), repository = try Repository(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        var remote = initial
        let task = ScheduledTask(courseID: initial.courses[0].id, start: now.addingTimeInterval(-7200),
                                 durationMinutes: 60, lessonID: "a")
        remote.tasks.append(task)
        try remote.confirm(taskID: task.id, actualMinutes: 20, now: now)
        repository.beforeOrderSave = { try repository.local.save(remote) }
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, remote)
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.local.loadLedger().materialize(), remote)
        XCTAssertEqual(draft.deleted, ["a"])
        XCTAssertTrue(store.errorMessage?.contains("学习记录或进度") == true)
    }

    @MainActor func testLateIndependentEditAndConfirmationSurviveReorder() async throws {
        let initial = fixture(), repository = try Repository(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var remote = initial
        remote.courses[0].name = "新名称"
        let task = ScheduledTask(courseID: initial.courses[0].id, start: now.addingTimeInterval(-7200),
                                 durationMinutes: 60, lessonID: "a")
        remote.tasks.append(task)
        try remote.confirm(taskID: task.id, actualMinutes: 20, now: now)
        repository.beforeOrderSave = { try repository.local.save(remote) }
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.state.courses[0].name, "新名称")
        XCTAssertEqual(store.state.courses[0].lessonOrder, draft.order)
        XCTAssertEqual(store.state.completions, remote.completions)
        XCTAssertEqual(store.state.tasks, remote.tasks)
        XCTAssertEqual(try repository.load(), store.state)
        XCTAssertEqual(try repository.local.loadLedger().materialize(), store.state)
    }

    @MainActor func testDiskDeletionBeforeUIRefreshCannotReviveCourse() async throws {
        let initial = fixture(), repository = try LocalRepository(inMemory: true)
        try repository.save(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        draft.order = ["b", "a", "c"]
        var remote = initial
        remote.removeCourse(id: initial.courses[0].id)
        try repository.save(remote)
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, remote)
        XCTAssertEqual(try repository.loadLedger().materialize(), remote)
        XCTAssertEqual(draft.order, ["b", "a", "c"])
    }

    @MainActor func testFailedWriteKeepsStateHistoryAndPendingDeletion() async throws {
        let initial = fixture(), repository = try Repository(initial)
        let store = store(initial, repository)
        var draft = LessonOrderDraft(course: initial.courses[0], state: initial)
        try draft.removeLessons(["a"])
        let records = try repository.local.loadLedger().records
        repository.beforeOrderSave = { throw CocoaError(.fileWriteUnknown) }
        let saved = await store.saveLessonOrder(draft, now: now)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, initial)
        XCTAssertEqual(try repository.load(), initial)
        XCTAssertEqual(try repository.local.loadLedger().records, records)
        XCTAssertEqual(draft.deleted, ["a"])
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertNotNil(store.errorMessage)
    }
}
