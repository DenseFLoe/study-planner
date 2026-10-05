import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class DailyTaskSwapTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        var holdSave = false
        @MainActor var resumeSave: CheckedContinuation<Void, Never>?
        @MainActor private var startedObserver: CheckedContinuation<Void, Never>?
        @MainActor func waitUntilSaving() async {
            if resumeSave != nil { return }
            await withCheckedContinuation { startedObserver = $0 }
        }
        @MainActor func saveForInteraction(_ state: PlannerState) async throws {
            if holdSave {
                await withCheckedContinuation { continuation in
                    resumeSave = continuation
                    startedObserver?.resume()
                    startedObserver = nil
                }
            }
            try save(state)
        }
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }

    private func fixture() -> (PlannerState, ScheduleResult, StudyLoadAssessment?) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        var state = PlannerState()
        state.courses = (0..<4).map {
            Course(name: "课程\($0)", totalMinutes: 60 * 90, startDate: day,
                   deadline: cal.date(byAdding: .day, value: 89, to: day)!)
        }
        let plan = state.replan(now: day)
        return (state, plan, StudyLoadAnalyzer().assess(state: state, now: day))
    }

    private func pair(in state: PlannerState) -> (UUID, UUID) {
        let source = state.tasks[0]
        let target = state.tasks.first {
            $0.courseID != source.courseID && Calendar.current.isDate($0.start, inSameDayAs: source.start)
        }!
        return (source.id, target.id)
    }

    @MainActor func testSwapUpdatesSavedStateAndCachedTasksWithoutChangingAssessment() async throws {
        let (state, plan, load) = fixture()
        let repo = Repository()
        let store = PlannerStore(state: state, repository: repo, result: plan, studyLoad: load)
        let (a, b) = pair(in: state)
        var expected = state
        try expected.swapDailyTasks(a, b)
        store.swapDailyTasks(a, b)
        XCTAssertEqual(store.state, expected)
        let saved = await store.waitForOrderSave()
        XCTAssertTrue(saved)
        XCTAssertEqual(repo.saved, expected)
        XCTAssertEqual(store.result.tasks, expected.tasks)
        XCTAssertEqual(store.result.risks, plan.risks)
        XCTAssertEqual(store.result.demands.keys.sorted(), plan.demands.keys.sorted())
        XCTAssertEqual(store.studyLoad?.requiredMinutes, load?.requiredMinutes)
        XCTAssertEqual(store.studyLoad?.availableMinutes, load?.availableMinutes)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testFailedSaveAndSyncLeaveStateAndCacheUnchanged() async {
        let (state, plan, load) = fixture()
        let repo = Repository()
        let store = PlannerStore(state: state, repository: repo, result: plan, studyLoad: load)
        let (a, b) = pair(in: state)
        repo.fails = true
        store.swapDailyTasks(a, b)
        let saved = await store.waitForOrderSave()
        XCTAssertFalse(saved)
        XCTAssertEqual(store.state, state)
        XCTAssertEqual(store.result.tasks, plan.tasks)
        XCTAssertNotNil(store.errorMessage)
        repo.fails = false
        store.syncBusy = true
        store.swapDailyTasks(a, b)
        XCTAssertEqual(store.state, state)
        XCTAssertNil(repo.saved)
    }

    @MainActor func testSlowSavePublishesImmediatelyAndGatesOtherWrites() async throws {
        let (state, plan, load) = fixture()
        let repo = Repository()
        repo.holdSave = true
        let store = PlannerStore(state: state, repository: repo, result: plan, studyLoad: load)
        let (a, b) = pair(in: state)
        var expected = state
        try expected.swapDailyTasks(a, b)
        store.swapDailyTasks(a, b)
        XCTAssertEqual(store.state, expected)
        XCTAssertTrue(store.orderSaveBusy)
        XCTAssertNil(repo.saved)
        await repo.waitUntilSaving()
        // The main actor is responsive while the repository remains suspended.
        XCTAssertFalse(store.change(replan: false) { $0.tasks.removeAll() })
        store.swapDailyTasks(a, b)
        XCTAssertEqual(store.state, expected)
        repo.resumeSave?.resume()
        let saved = await store.waitForOrderSave()
        XCTAssertTrue(saved)
        XCTAssertFalse(store.orderSaveBusy)
        XCTAssertEqual(repo.saved, expected)
    }

    @MainActor func testCompareFullRecalculationWithSwapFastPath() async throws {
        let (state, plan, load) = fixture()
        let (a, b) = pair(in: state)
        // Both timings include actual persistence, on separate isolated stores.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldRepo = try LocalRepository(url: directory.appendingPathComponent("old.store"))
        let fastRepo = try LocalRepository(url: directory.appendingPathComponent("fast.store"))
        try oldRepo.save(state)
        try fastRepo.save(state)
        let store = PlannerStore(state: state, repository: fastRepo, result: plan, studyLoad: load)
        let clock = ContinuousClock()
        let oldTime = try clock.measure {
            var next = state
            try next.swapDailyTasks(a, b)
            _ = ScheduleEngine().generate(state: next, now: Date())
            try oldRepo.save(next)
            _ = StudyLoadAnalyzer().assess(state: next, now: Date())
        }
        let start = clock.now
        let fastTime = clock.measure { store.swapDailyTasks(a, b) }
        let saved = await store.waitForOrderSave()
        let committedTime = start.duration(to: clock.now)
        XCTAssertTrue(saved)
        XCTAssertNil(store.errorMessage)
        let restored = try LocalRepository(url: directory.appendingPathComponent("fast.store")).load()
        XCTAssertEqual(restored.tasks, store.state.tasks)
        XCTAssertEqual(restored.settings, store.state.settings)
        XCTAssertEqual(restored.courses.sorted { $0.id < $1.id }, store.state.courses.sorted { $0.id < $1.id })
        print("SWAP_BENCHMARK tasks=\(state.tasks.count) full=\(oldTime) interaction=\(fastTime) committed=\(committedTime)")
    }
}
