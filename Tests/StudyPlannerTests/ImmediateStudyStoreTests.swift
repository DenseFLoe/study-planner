import XCTest
@testable import StudyCore
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

    @MainActor func testSavesCompletePlanAndUpdatesCachedResult() async throws {
        let (state, result, now) = fixture()
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: result)
        let started = await store.studyImmediately(courseID: state.courses[0].id, now: now)
        XCTAssertTrue(started)
        XCTAssertEqual(repository.saved, store.state)
        XCTAssertEqual(store.result.tasks, store.state.tasks)
        XCTAssertEqual(store.result.tasks.first?.id, store.state.settings.immediateStudy?.task.id)
        XCTAssertNotNil(store.studyLoad)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testFailedPersistencePreservesStateAndSyncAllowsImmediateStudy() async {
        let (state, result, now) = fixture()
        let repository = Repository()
        repository.fails = true
        let store = PlannerStore(state: state, repository: repository, result: result)
        let failedStart = await store.studyImmediately(courseID: state.courses[0].id, now: now)
        XCTAssertFalse(failedStart)
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertNil(repository.saved)
        XCTAssertNotNil(store.errorMessage)
        repository.fails = false
        store.syncBusy = true
        let retriedStart = await store.studyImmediately(courseID: state.courses[0].id, now: now)
        XCTAssertTrue(retriedStart)
        XCTAssertEqual(repository.saved, store.state)
        XCTAssertEqual(store.result.tasks, store.state.tasks)
        XCTAssertNotNil(store.state.settings.immediateStudy)
    }

    @MainActor func testSelectedLessonIsSavedAndDisplayedAheadOfEarlierLesson() async throws {
        let (state, result, now) = fixture()
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: result)
        let lessonStarted = await store.studyImmediately(courseID: state.courses[0].id, lessonID: "2", now: now)
        XCTAssertTrue(lessonStarted)
        let saved = try XCTUnwrap(repository.saved)
        XCTAssertEqual(saved, store.state)
        XCTAssertEqual(saved.settings.immediateStudy?.task.lessonID, "2")
        XCTAssertEqual(store.result.tasks.map(\.lessonID), ["2", "1"])
        XCTAssertEqual(store.result.tasks.first?.start, now)
        XCTAssertEqual(store.result.tasks, saved.tasks)
        XCTAssertTrue(saved.completions.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testFullTodayMovesUnconfirmedLessonsToTomorrowAndPersistsReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("immediate-displacement.store")
        let repository = try LocalRepository(url: url)
        let calendar = Calendar.current
        let engine = ScheduleEngine(calendar: calendar)
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let now = engine.instant(day: today, minute: 510)
        var original = Course(name: "原有课程", totalMinutes: 135, startDate: today, deadline: tomorrow)
        original.type = .lessonBasedRecorded
        original.manualLessons = (0..<3).map { .init(id: "old-\($0)", name: "原有第\($0)节", durationMinutes: 45) }
        var selected = Course(name: "立刻上的课程", totalMinutes: 60, startDate: today, deadline: tomorrow)
        selected.type = .lessonBasedRecorded
        selected.manualLessons = [.init(id: "selected", name: "选中课节", durationMinutes: 60)]
        var state = PlannerState()
        state.courses = [original, selected]
        let weekday = calendar.component(.weekday, from: today)
        state.settings.availability = (1...7).map {
            .init(weekday: $0, startMinute: 480, endMinute: $0 == weekday ? 600 : 720)
        }
        state.fixedEvents = [.init(title: "明早固定事项", startMinute: 480, endMinute: 540,
                                   startDate: tomorrow, endDate: tomorrow)]
        let history = ScheduledTask(courseID: original.id, start: engine.instant(day: today, minute: 390),
                                    durationMinutes: 45, lessonID: "old-0")
        let displaced = [
            ScheduledTask(courseID: original.id, start: engine.instant(day: today, minute: 480),
                          durationMinutes: 45, lessonID: "old-1"),
            ScheduledTask(courseID: original.id, start: engine.instant(day: today, minute: 540),
                          durationMinutes: 45, lessonID: "old-2")
        ]
        let previousSelected = ScheduledTask(courseID: selected.id, start: engine.instant(day: tomorrow, minute: 540),
                                            durationMinutes: 60, lessonID: "selected")
        state.tasks = [history] + displaced + [previousSelected]
        try state.confirm(taskID: history.id, actualMinutes: 45, now: history.end, calendar: calendar)
        state.settings.dailyTaskOrders = [.init(day: today, keys: DailyTaskOrder.keys(for: displaced))]
        try repository.save(state)
        let staleRows = try repository.loadLedger().changes(after: 0)
        let store = PlannerStore(state: state, repository: repository,
                                 result: engine.assessSavedPlan(state: state, now: now))

        let started = await store.studyImmediately(courseID: selected.id, lessonID: "selected", now: now)
        XCTAssertTrue(started)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.result.tasks.first?.start, now)
        XCTAssertEqual(store.result.tasks.first?.lessonID, "selected")
        XCTAssertEqual(store.result.tasks.first?.durationMinutes, 60)
        XCTAssertEqual(store.result.tasks.filter { calendar.isDate($0.start, inSameDayAs: today) }.count, 1)
        let moved = store.result.tasks.filter { $0.courseID == original.id }
        XCTAssertEqual(moved.map(\.lessonID), ["old-1", "old-2"])
        XCTAssertEqual(moved.map(\.durationMinutes), [45, 45])
        XCTAssertTrue(moved.allSatisfy { calendar.isDate($0.start, inSameDayAs: tomorrow) &&
            $0.start >= engine.instant(day: tomorrow, minute: 540) && $0.end <= engine.instant(day: tomorrow, minute: 720) })
        for (first, second) in zip(store.result.tasks, store.result.tasks.dropFirst()) {
            XCTAssertLessThanOrEqual(first.end.addingTimeInterval(900), second.start)
        }
        XCTAssertTrue(store.result.risks.isEmpty)
        XCTAssertEqual(store.state.completions, state.completions)
        XCTAssertEqual(store.state.fixedEvents, state.fixedEvents)
        XCTAssertEqual(store.state.tasks.first { $0.id == history.id }, state.tasks.first { $0.id == history.id })
        XCTAssertEqual(store.state.remainingMinutes(for: original), 90)
        XCTAssertEqual(store.state.remainingMinutes(for: selected), 60)
        XCTAssertEqual(store.result.tasks, store.state.tasks.filter(\.isUnconfirmed))
        let oldIDs = Set((displaced + [previousSelected]).map(\.id))
        XCTAssertTrue(oldIDs.isDisjoint(with: store.state.tasks.map(\.id)))

        let reopened = try LocalRepository(url: url)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.tasks, store.state.tasks)
        XCTAssertEqual(loaded.settings.immediateStudy, store.state.settings.immediateStudy)
        XCTAssertEqual(loaded.completions, state.completions)
        var ledger = try reopened.loadLedger()
        try ledger.merge(staleRows)
        let peer = try ledger.materialize()
        XCTAssertEqual(Set(peer.tasks.map(\.id)), Set(loaded.tasks.map(\.id)))
        XCTAssertEqual(peer.completions, loaded.completions)
        XCTAssertTrue(oldIDs.isDisjoint(with: peer.tasks.map(\.id)))
    }

    @MainActor func testSelectedLessonSaveFailurePreservesPreviousPlanAndRequest() async throws {
        var (state, result, now) = fixture()
        result = try state.studyImmediately(courseID: state.courses[0].id, now: now)
        let repository = Repository()
        repository.fails = true
        let store = PlannerStore(state: state, repository: repository, result: result)
        let lessonStartFailed = await store.studyImmediately(courseID: state.courses[0].id, lessonID: "2", now: now)
        XCTAssertFalse(lessonStartFailed)
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, result.tasks)
        XCTAssertEqual(store.state.settings.immediateStudy?.task.lessonID, "1")
        XCTAssertNil(repository.saved)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testImpossibleRequestDoesNotWriteRepository() async {
        var (state, result, now) = fixture()
        state.fixedEvents = [.init(title: "占用", startMinute: 480, endMinute: 600, startDate: now, endDate: now)]
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: result)
        let impossibleStart = await store.studyImmediately(courseID: state.courses[0].id, now: now)
        XCTAssertFalse(impossibleStart)
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
