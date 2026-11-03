import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class CourseEditingStoreTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }

    private func fixture() throws -> PlannerState {
        let now = Date().addingTimeInterval(-86400)
        var state = PlannerState()
        state.settings.availability = []
        var course = Course(name: "手动课程", totalMinutes: 180, startDate: now,
                            deadline: now.addingTimeInterval(86400 * 4))
        course.type = .lessonBasedRecorded
        course.manualLessons = ["a", "b", "c"].map { .init(id: $0, name: $0, durationMinutes: 60) }
        course.lessonOrder = ["a", "b", "c"]
        state.courses = [course]
        for (index, minutes) in [60, 20].enumerated() {
            let task = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(Double(index * 7200)),
                                     durationMinutes: 60, lessonID: index == 0 ? "a" : "b")
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: minutes, now: task.end)
        }
        return state
    }

    @MainActor private func store(_ state: PlannerState, repository: Repository) -> PlannerStore {
        PlannerStore(state: state, repository: repository,
                     result: ScheduleEngine().generate(state: state, now: Date()))
    }

    @MainActor func testSavingManualDeletionDoesNotCompleteUntouchedLessons() async throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst()
        edited.totalMinutes = 120
        let savedDeletion = await store.saveCourse(edited)
        XCTAssertTrue(savedDeletion)
        let course = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(course.deletedLessonIDs, ["a"])
        XCTAssertEqual(store.state.lessonWorkItems(for: course).map(\.remainingMinutes), [40, 60])
        XCTAssertEqual(store.state.completions, state.completions.filter { $0.taskID == state.tasks[1].id })
        XCTAssertFalse(store.state.tasks.contains { $0.lessonID == "a" })
        XCTAssertEqual(repository.saved, store.state)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testDraftDeletionAdjustsBaselineAndMatchesSavedPreview() async throws {
        var state = try fixture()
        state.tasks = []; state.completions = []
        state.courses[0].initialCompletedMinutes = 70
        let repository = Repository()
        let store = store(state, repository: repository)
        var preview = state
        try preview.updateCourse(state.courses[0])
        try preview.removeLessons(courseID: state.courses[0].id, ids: ["a"])
        let edited = preview.courses[0]
        XCTAssertEqual(edited.initialCompletedMinutes, 10)
        XCTAssertEqual(store.state, state, "Draft changes must not mutate the original store")
        let savedDraft = await store.saveCourse(edited)
        XCTAssertTrue(savedDraft)
        let saved = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(saved.initialCompletedMinutes, edited.initialCompletedMinutes)
        XCTAssertEqual(store.state.lessonWorkItems(for: saved), preview.lessonWorkItems(for: edited))
        XCTAssertEqual(store.state.lessonWorkItems(for: saved).map(\.remainingMinutes), [50, 60])
    }

    @MainActor func testFailedSavePreservesCourseAndCompletionRecords() async throws {
        let state = try fixture(), repository = Repository()
        repository.fails = true
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst(); edited.totalMinutes = 120
        let saveFailed = await store.saveCourse(edited)
        XCTAssertFalse(saveFailed)
        XCTAssertEqual(store.state, state)
        XCTAssertNil(repository.saved)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testUnidentifiedLegacyCompletionBlocksDeletionWithoutSaving() async throws {
        var state = try fixture()
        state.tasks[0].lessonID = nil
        let repository = Repository()
        let savedStore = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst(); edited.totalMinutes = 120
        let legacyDeletionRejected = await savedStore.saveCourse(edited)
        XCTAssertFalse(legacyDeletionRejected)
        XCTAssertEqual(savedStore.state, state)
        XCTAssertNil(repository.saved)
        XCTAssertTrue(savedStore.errorMessage?.contains("没有课节标识") == true)
    }

    @MainActor func testReplacingOriginalLessonsRetainsNewLessonAndDeletionMarkers() async throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons = [.init(id: "new", name: "新课节", durationMinutes: 60)]
        edited.totalMinutes = 60
        let replacementSaved = await store.saveCourse(edited)
        XCTAssertTrue(replacementSaved)
        let course = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(course.deletedLessonIDs, ["a", "b", "c"])
        XCTAssertEqual(store.state.lessonWorkItems(for: course).map(\.remainingMinutes), [60])
        XCTAssertTrue(store.state.completions.isEmpty)
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertEqual(repository.saved, store.state)
    }

    @MainActor func testStaleNameDraftPreservesNewLessonsAndLatestSchedulingSettings() async throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        let baseline = state.courses[0]
        var latest = baseline
        latest.manualLessons!.append(.init(id: "d", name: "新增课节", durationMinutes: 60))
        latest.totalMinutes += 60
        latest.priority = 5
        latest.notes = "同步带来的备注"
        let refreshed = await store.saveCourse(latest)
        XCTAssertTrue(refreshed)
        latest = try XCTUnwrap(store.course(baseline.id))
        let tasks = store.state.tasks
        var draft = baseline
        draft.name = "本地改名"
        let saved = await store.saveCourse(draft, from: baseline)
        XCTAssertTrue(saved)
        latest.name = draft.name
        XCTAssertEqual(store.course(baseline.id), latest)
        XCTAssertEqual(store.state.tasks, tasks)
        XCTAssertEqual(store.state.completions, state.completions)
    }

    @MainActor func testStaleDraftCannotRecreateDeletedCourse() async throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        let baseline = state.courses[0]
        let deleted = await store.deleteCourse(baseline)
        XCTAssertTrue(deleted)
        let afterDeletion = store.state
        var draft = baseline
        draft.name = "旧窗口里的名称"
        let saved = await store.saveCourse(draft, from: baseline)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, afterDeletion)
        XCTAssertEqual(repository.saved, afterDeletion)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testDraftCannotRecreateCourseDeletedOnDiskBeforeUIRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("planner.store")
        let original = try fixture(), baseline = original.courses[0]
        let repository = try LocalRepository(url: url)
        try repository.save(original)
        let store = PlannerStore(state: original, repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: original, now: Date()))
        let peer = try LocalRepository(url: url)
        var deleted = original
        deleted.removeCourse(id: baseline.id)
        _ = try peer.saveChanges(deleted, from: original)
        var draft = baseline
        draft.name = "同步完成前保存的草稿"
        let saved = await store.saveCourse(draft, from: baseline)
        XCTAssertFalse(saved)
        let reopened = try LocalRepository(url: url)
        XCTAssertTrue(try reopened.load().courses.isEmpty)
        XCTAssertTrue(try reopened.loadLedger().materialize().courses.isEmpty)
        XCTAssertTrue(try reopened.load().completions.isEmpty)
    }

    @MainActor func testConflictingDraftDoesNotOverwriteLatestCourse() async throws {
        for schedulingConflict in [false, true] {
            let state = try fixture(), repository = Repository()
            let store = store(state, repository: repository)
            let baseline = state.courses[0]
            var latest = baseline, draft = baseline
            if schedulingConflict {
                latest.manualLessons![0].durationMinutes += 30
                latest.totalMinutes += 30
                draft.manualLessons!.removeLast()
                draft.totalMinutes -= 60
            } else {
                latest.name = "同步后的名称"
                draft.name = "旧窗口里的另一名称"
            }
            let refreshed = await store.saveCourse(latest)
            XCTAssertTrue(refreshed)
            let beforeSave = store.state
            let saved = await store.saveCourse(draft, from: baseline)
            XCTAssertFalse(saved)
            XCTAssertEqual(store.state, beforeSave)
            XCTAssertEqual(repository.saved, beforeSave)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    @MainActor func testSchedulingDraftKeepsConcurrentDisplayEditAndOptionalRemoval() async throws {
        var state = try fixture()
        state.courses[0].dailyStudyWeight = 2
        let repository = Repository(), baseline = state.courses[0]
        let store = store(state, repository: repository)
        var latest = baseline
        latest.name = "新名称"; latest.color = "green"
        let refreshed = await store.saveCourse(latest)
        XCTAssertTrue(refreshed)
        var draft = baseline
        draft.dailyStudyWeight = nil
        draft.notes = "本地备注"
        let saved = await store.saveCourse(draft, from: baseline)
        XCTAssertTrue(saved)
        draft.name = latest.name; draft.color = latest.color
        XCTAssertEqual(store.course(baseline.id), draft)
    }
}
