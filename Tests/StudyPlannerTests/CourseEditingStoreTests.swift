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

    @MainActor func testSavingManualDeletionDoesNotCompleteUntouchedLessons() throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst()
        edited.totalMinutes = 120
        XCTAssertTrue(store.saveCourse(edited))
        let course = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(course.deletedLessonIDs, ["a"])
        XCTAssertEqual(store.state.lessonWorkItems(for: course).map(\.remainingMinutes), [40, 60])
        XCTAssertEqual(store.state.completions, state.completions.filter { $0.taskID == state.tasks[1].id })
        XCTAssertFalse(store.state.tasks.contains { $0.lessonID == "a" })
        XCTAssertEqual(repository.saved, store.state)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testDraftDeletionAdjustsBaselineAndMatchesSavedPreview() throws {
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
        XCTAssertTrue(store.saveCourse(edited))
        let saved = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(saved.initialCompletedMinutes, edited.initialCompletedMinutes)
        XCTAssertEqual(store.state.lessonWorkItems(for: saved), preview.lessonWorkItems(for: edited))
        XCTAssertEqual(store.state.lessonWorkItems(for: saved).map(\.remainingMinutes), [50, 60])
    }

    @MainActor func testFailedSavePreservesCourseAndCompletionRecords() throws {
        let state = try fixture(), repository = Repository()
        repository.fails = true
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst(); edited.totalMinutes = 120
        XCTAssertFalse(store.saveCourse(edited))
        XCTAssertEqual(store.state, state)
        XCTAssertNil(repository.saved)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testUnidentifiedLegacyCompletionBlocksDeletionWithoutSaving() throws {
        var state = try fixture()
        state.tasks[0].lessonID = nil
        let repository = Repository()
        let savedStore = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons!.removeFirst(); edited.totalMinutes = 120
        XCTAssertFalse(savedStore.saveCourse(edited))
        XCTAssertEqual(savedStore.state, state)
        XCTAssertNil(repository.saved)
        XCTAssertTrue(savedStore.errorMessage?.contains("没有课节标识") == true)
    }

    @MainActor func testReplacingOriginalLessonsRetainsNewLessonAndDeletionMarkers() throws {
        let state = try fixture(), repository = Repository()
        let store = store(state, repository: repository)
        var edited = state.courses[0]
        edited.manualLessons = [.init(id: "new", name: "新课节", durationMinutes: 60)]
        edited.totalMinutes = 60
        XCTAssertTrue(store.saveCourse(edited))
        let course = try XCTUnwrap(store.course(edited.id))
        XCTAssertEqual(course.deletedLessonIDs, ["a", "b", "c"])
        XCTAssertEqual(store.state.lessonWorkItems(for: course).map(\.remainingMinutes), [60])
        XCTAssertTrue(store.state.completions.isEmpty)
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertEqual(repository.saved, store.state)
    }
}
