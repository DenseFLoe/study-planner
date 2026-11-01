import XCTest
import StudyCore
import StudyPersistence
@testable import StudySync
@testable import StudyPlanner

private actor SyncStage {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?

    func hold() async {
        if started { return }
        await withCheckedContinuation { continuation in
            resume = continuation
            started = true
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { resume?.resume(); resume = nil }
}

final class CloudSyncPresentationTests: XCTestCase {
    @MainActor private func store(state: PlannerState = PlannerState()) throws -> PlannerStore {
        let repository = try LocalRepository(inMemory: true)
        try repository.save(state)
        return PlannerStore(state: state, repository: repository,
                            result: ScheduleEngine().generate(state: state, now: Date()))
    }

    @MainActor func testBusyIndicatorCoversTransferAndRefreshWhileMainActorResponds() async throws {
        let store = try store()
        let transfer = SyncStage(), refresh = SyncStage()
        var state = PlannerState()
        state.courses = [Course(name: "同步课程", totalMinutes: 60, startDate: Date(), deadline: Date())]
        state.courses[0].autoScheduleEnabled = false
        let loaded = state
        let ledger = SyncLedger()
        store.beginCloudSync(operation: {
            XCTAssertFalse(Thread.isMainThread)
            await transfer.hold()
            return SyncOutcome(state: loaded, ledger: ledger, sent: 1, received: 1)
        }, snapshot: {
            XCTAssertFalse(Thread.isMainThread)
            await refresh.hold()
            return (loaded, ledger)
        })
        let task = store.syncTask
        XCTAssertTrue(store.syncBusy, "Show progress before starting any work")
        await transfer.waitUntilStarted()
        XCTAssertTrue(store.syncBusy)
        XCTAssertTrue(store.state.courses.isEmpty)
        // A second request must not start a competing transaction.
        store.beginCloudSync(operation: { XCTFail("Duplicate transfer"); throw URLError(.cancelled) })
        await transfer.release()
        await refresh.waitUntilStarted()
        XCTAssertTrue(store.syncBusy, "Keep progress visible during the local refresh")
        XCTAssertTrue(store.state.courses.isEmpty, "Publish the state and its calculations together")
        await refresh.release()
        await task?.value
        XCTAssertFalse(store.syncBusy)
        XCTAssertNil(store.syncTask)
        XCTAssertEqual(store.state, loaded)
        XCTAssertEqual(store.studyLoad?.requiredMinutes, 60)
        XCTAssertEqual(store.result.tasks, ScheduleEngine().generate(state: loaded, now: Date()).tasks)
        XCTAssertTrue(store.cloudStatus.hasPrefix("已同步"))
    }

    @MainActor func testTransferFailureRefreshesLocalStateAndClearsProgress() async throws {
        let store = try store()
        let state = store.state
        store.beginCloudSync(operation: { throw URLError(.networkConnectionLost) },
                             snapshot: { (state, SyncLedger()) })
        await store.syncTask?.value
        XCTAssertFalse(store.syncBusy)
        XCTAssertNil(store.syncTask)
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.state, state)
        XCTAssertTrue(store.cloudStatus.hasPrefix("云同步未完成，待传数据已保留"))
    }

    @MainActor func testRefreshFailurePreservesDisplayedDataAndClearsProgress() async throws {
        let store = try store()
        let state = store.state
        store.beginCloudSync(operation: { throw URLError(.notConnectedToInternet) },
                             snapshot: { throw CocoaError(.fileReadCorruptFile) })
        await store.syncTask?.value
        XCTAssertFalse(store.syncBusy)
        XCTAssertNil(store.syncTask)
        XCTAssertFalse(store.isReady)
        XCTAssertEqual(store.state, state)
        XCTAssertTrue(store.errorMessage?.hasPrefix("无法读取本地日程") == true)
    }

    @MainActor func testSavingAfterSyncPreservesRowsWrittenInBackground() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("local.store")
        let repository = try LocalRepository(url: database)
        var initial = PlannerState()
        initial.settings.availability = []
        try repository.save(initial)
        let store = PlannerStore(state: try repository.load(), repository: repository,
                                 result: ScheduleEngine().generate(state: initial, now: Date()))
        store.beginCloudSync(operation: {
            try await SyncDatabase.update(url: database) { state, _ in
                state.courses.append(Course(name: "远端新增", totalMinutes: 60, startDate: Date(), deadline: Date()))
            }
            let (state, ledger) = try await SyncDatabase.snapshot(url: database)
            return SyncOutcome(state: state, ledger: ledger, sent: 0, received: 1)
        }, snapshot: { try await SyncDatabase.snapshot(url: database) })
        await store.syncTask?.value
        XCTAssertTrue(store.isReady)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.state.courses.map(\.name), ["远端新增"])
        XCTAssertTrue(store.change(replan: false) { $0.courses[0].name = "同步后编辑" })
        let saved = try LocalRepository(url: database).load()
        XCTAssertEqual(saved.courses.map(\.name), ["同步后编辑"])
    }

    @MainActor func testEditsDuringTransferAndRefreshPersistWithoutLosingRemoteRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("editable.store")
        let repository = try LocalRepository(url: database)
        var initial = PlannerState()
        initial.settings.availability = []
        initial.courses = [Course(name: "本地课程", totalMinutes: 60, startDate: Date(), deadline: Date())]
        try repository.save(initial)
        let store = PlannerStore(state: initial, repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: initial, now: Date()))
        let transfer = SyncStage(), refresh = SyncStage()
        store.beginCloudSync(operation: {
            await transfer.hold()
            try await SyncDatabase.update(url: database) { state, _ in
                state.courses.append(Course(name: "远端新增", totalMinutes: 60, startDate: Date(), deadline: Date()))
            }
            let (state, ledger) = try await SyncDatabase.snapshot(url: database)
            return SyncOutcome(state: state, ledger: ledger, sent: 1, received: 1)
        }, snapshot: {
            let snapshot = try await SyncDatabase.snapshot(url: database)
            await refresh.hold()
            return snapshot
        })
        let syncTask = store.syncTask
        await transfer.waitUntilStarted()
        XCTAssertTrue(store.change(replan: false) { $0.courses[0].name = "传输期间编辑" })
        XCTAssertEqual(try LocalRepository(url: database).load().courses[0].name, "传输期间编辑")
        await transfer.release()
        await refresh.waitUntilStarted()
        XCTAssertTrue(store.syncBusy)
        // The displayed state has not seen the newly committed remote course.
        XCTAssertEqual(store.state.courses.count, 1)
        XCTAssertTrue(store.change(replan: false) { $0.courses[0].name = "刷新期间编辑" })
        XCTAssertEqual(Set(store.state.courses.map(\.name)), ["刷新期间编辑", "远端新增"])
        await refresh.release()
        await syncTask?.value
        XCTAssertFalse(store.syncBusy)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(Set(store.state.courses.map(\.name)), ["刷新期间编辑", "远端新增"])
        let reopened = try LocalRepository(url: database)
        XCTAssertEqual(Set(try reopened.load().courses.map(\.name)), ["刷新期间编辑", "远端新增"])
        XCTAssertEqual(Set(try reopened.loadLedger().materialize().courses.map(\.name)), ["刷新期间编辑", "远端新增"])
    }

    @MainActor func testFailedTransferKeepsEditsMadeWhileOffline() async throws {
        let repository = try LocalRepository(inMemory: true)
        let store = PlannerStore(state: PlannerState(), repository: repository,
                                 result: ScheduleEngine().assessSavedPlan(state: PlannerState(), now: Date()))
        let transfer = SyncStage()
        // Snapshot the same isolated repository without crossing its context to a worker.
        let snapshot = OfflineSnapshot()
        store.beginCloudSync(operation: {
            await transfer.hold()
            throw URLError(.networkConnectionLost)
        }, snapshot: { await snapshot.value() })
        let task = store.syncTask
        await transfer.waitUntilStarted()
        XCTAssertTrue(store.change(replan: false) {
            $0.courses.append(Course(name: "断网期间新增", totalMinutes: 60, startDate: Date(), deadline: Date()))
        })
        await snapshot.set(state: try repository.load(), ledger: try repository.loadLedger())
        await transfer.release()
        await task?.value
        XCTAssertFalse(store.syncBusy)
        XCTAssertEqual(store.state.courses.map(\.name), ["断网期间新增"])
        XCTAssertEqual(try repository.load().courses.map(\.name), ["断网期间新增"])
        XCTAssertTrue(store.cloudStatus.hasPrefix("云同步未完成，待传数据已保留"))
    }
}

private actor OfflineSnapshot {
    var state = PlannerState()
    var ledger = SyncLedger()
    func set(state: PlannerState, ledger: SyncLedger) { self.state = state; self.ledger = ledger }
    func value() -> (PlannerState, SyncLedger) { (state, ledger) }
}
