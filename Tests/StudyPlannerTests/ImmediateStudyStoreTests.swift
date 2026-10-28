import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class ImmediateStudyStoreTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }

    private func fixture() -> (PlannerState, ScheduleResult, Date) {
        let calendar = Calendar.current
        let now = ScheduleEngine().instant(day: Date(), minute: 480)
        var state = PlannerState()
        var course = Course(name: "不定时课程", totalMinutes: 90, startDate: calendar.startOfDay(for: now),
                            deadline: calendar.date(byAdding: .day, value: 2, to: now)!)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "1", name: "第一节", durationMinutes: 60), .init(id: "2", name: "第二节", durationMinutes: 30)]
        state.courses = [course]
        let result = state.replan(now: now)
        return (state, result, now)
    }

    @MainActor func testSavesCompletePlanAndUpdatesCachedResult() throws {
        let (state, result, now) = fixture()
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: result)
        XCTAssertTrue(store.studyImmediately(courseID: state.courses[0].id, now: now))
        XCTAssertEqual(repository.saved, store.state)
        XCTAssertEqual(store.result.tasks, store.state.tasks)
        XCTAssertEqual(store.result.tasks.first?.id, store.state.settings.immediateStudy?.task.id)
        XCTAssertNotNil(store.studyLoad)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testFailedPersistenceAndSyncPreserveStateAndCachedResult() {
        let (state, result, now) = fixture()
        let repository = Repository()
        repository.fails = true
        let store = PlannerStore(state: state, repository: repository, result: result)
        XCTAssertFalse(store.studyImmediately(courseID: state.courses[0].id, now: now))
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertNil(repository.saved)
        XCTAssertNotNil(store.errorMessage)
        repository.fails = false
        store.syncBusy = true
        XCTAssertFalse(store.studyImmediately(courseID: state.courses[0].id, now: now))
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertNil(repository.saved)
    }

    @MainActor func testImpossibleRequestDoesNotWriteRepository() {
        var (state, result, now) = fixture()
        state.fixedEvents = [.init(title: "占用", startMinute: 480, endMinute: 600, startDate: now, endDate: now)]
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: result)
        XCTAssertFalse(store.studyImmediately(courseID: state.courses[0].id, now: now))
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertNil(repository.saved)
    }

    @MainActor func testSyncRefreshReappliesImmediateRequestToDisplayedPeerDrafts() async throws {
        let now = Date()
        let calendar = Calendar.current
        guard calendar.component(.hour, from: now) < 23 || calendar.component(.minute, from: now) < 58 else {
            throw XCTSkip("Immediate lesson must fit before local midnight")
        }
        var loaded = PlannerState()
        var course = Course(name: "立即学习", totalMinutes: 1, startDate: calendar.startOfDay(for: now), deadline: now)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "sync-lesson", name: "本节", durationMinutes: 1)]
        loaded.courses = [course]
        loaded.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 0, endMinute: 1440) }
        _ = try loaded.studyImmediately(courseID: course.id, now: now)
        let request = try XCTUnwrap(loaded.settings.immediateStudy)
        loaded.tasks[0].start = request.task.start.addingTimeInterval(600)
        let peer = loaded
        let repository = Repository()
        let store = PlannerStore(state: peer, repository: repository,
                                 result: ScheduleEngine().generate(state: peer, now: now))
        store.beginCloudSync(operation: { throw URLError(.cancelled) }, snapshot: { (peer, SyncLedger()) })
        await store.syncTask?.value
        XCTAssertEqual(store.state.tasks.first { $0.id == request.task.id }, request.task)
        XCTAssertEqual(store.result.tasks, store.state.tasks)
        XCTAssertEqual(store.state.settings.immediateStudy, request)
        XCTAssertFalse(store.syncBusy)
        XCTAssertNil(store.errorMessage)
    }
}
