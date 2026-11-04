import XCTest
@testable import StudyCore
import StudyPersistence
@testable import StudySync
@testable import StudyPlanner

final class SettingsDraftTests: XCTestCase {
    @MainActor private func fixture() throws -> (PlannerStore, LocalRepository) {
        let original = PlannerState()
        let repository = try LocalRepository(inMemory: true)
        try repository.save(original)
        return (PlannerStore(state: original, repository: repository,
                             result: ScheduleEngine().generate(state: original, now: Date())), repository)
    }

    @MainActor func testReopeningSettingsRetainsDraftWithoutSavingAndRestoreDiscardsIt() throws {
        let (store, repository) = try fixture()
        let original = store.state
        let draft = store.settingsDraft
        draft.refresh(from: original.settings)
        draft.settings.availability[0].startMinute = 600
        // SettingsView is rebuilt on navigation; each new view uses this same
        // store-owned draft and calls refresh on appearance.
        _ = SettingsView(store: store)
        store.settingsDraft.refresh(from: store.state.settings)
        XCTAssertTrue(draft === store.settingsDraft)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.settings.availability[0].startMinute, 600)
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(try repository.load(), original)
        draft.restore(from: store.state.settings)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertEqual(draft.settings, original.settings)
        XCTAssertEqual(try repository.load(), original)
    }

    @MainActor func testCleanDraftRefreshesButDirtyDraftKeepsItsOriginalBaseline() {
        let original = AppSettings(), draft = SettingsDraft()
        draft.refresh(from: original)
        var remote = original
        remote.minimumScheduleUnit = 30
        draft.refresh(from: remote)
        XCTAssertEqual(draft.settings, remote)
        XCTAssertFalse(draft.hasChanges)
        draft.settings.notificationMinute = 1200
        var newer = remote
        newer.minimumScheduleUnit = 45
        draft.refresh(from: newer)
        XCTAssertEqual(draft.baseline, remote)
        XCTAssertEqual(draft.settings.minimumScheduleUnit, 30)
        XCTAssertTrue(draft.hasChanges)
    }

    @MainActor func testConflictingSaveRetainsDraftAndLatestSavedState() async throws {
        let (store, repository) = try fixture()
        let draft = store.settingsDraft
        draft.refresh(from: store.state.settings)
        draft.settings.minimumScheduleUnit = 45
        let updated = await store.change(replan: false) { $0.settings.minimumScheduleUnit = 30 }
        XCTAssertTrue(updated)
        let latest = store.state, backupCount = store.backupEntries.count
        let saved = await draft.save(using: store)
        XCTAssertFalse(saved)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.settings.minimumScheduleUnit, 45)
        XCTAssertEqual(store.state, latest)
        XCTAssertEqual(try repository.load(), latest)
        XCTAssertEqual(store.backupEntries.count, backupCount)
        XCTAssertTrue(store.errorMessage?.contains("冲突") == true)
    }

    @MainActor func testExplicitSaveResetsBaselineAndInvalidSaveRetainsDraft() async throws {
        let (store, repository) = try fixture()
        let draft = store.settingsDraft
        draft.refresh(from: store.state.settings)
        draft.settings.minimumScheduleUnit = 0
        let invalid = await draft.save(using: store)
        XCTAssertFalse(invalid)
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(try repository.load().settings.minimumScheduleUnit, 60)
        draft.settings.minimumScheduleUnit = 30
        let saved = await draft.save(using: store)
        XCTAssertTrue(saved)
        XCTAssertFalse(draft.hasChanges)
        XCTAssertTrue(draft.saved)
        XCTAssertEqual(draft.baseline, store.state.settings)
        XCTAssertEqual(try repository.load().settings.minimumScheduleUnit, 30)
    }

    func testMergePreservesRuntimeFieldsAndUntouchedCollections() throws {
        let original = AppSettings()
        var edited = original, current = original
        edited.notificationMinute = 1200
        current.actualStudyStart = Date()
        current.dailyTaskOrders = [.init(day: Date(), keys: ["remote-order"])]
        current.immediateStudy = .init(task: ScheduledTask(courseID: UUID(), start: Date(), durationMinutes: 60))
        current.availability[0].startMinute = 600
        current.schedulingRuleLevels = ["remote-rule": 2]
        let merged = try edited.mergingSettingsDraft(from: original, into: current)
        var expected = current
        expected.notificationMinute = 1200
        XCTAssertEqual(merged, expected)
        var runtimeOnly = original
        runtimeOnly.actualStudyStart = current.actualStudyStart
        runtimeOnly.dailyTaskOrders = current.dailyTaskOrders
        runtimeOnly.immediateStudy = current.immediateStudy
        XCTAssertTrue(runtimeOnly.hasSameEditableSettings(as: original))
    }

    func testSameValueMergeAndConflictingWindowCollection() throws {
        let original = AppSettings()
        var edited = original, current = original
        edited.minimumScheduleUnit = 30
        current.minimumScheduleUnit = 30
        XCTAssertEqual(try edited.mergingSettingsDraft(from: original, into: current).minimumScheduleUnit, 30)
        edited.availability[0].startMinute = 600
        current.availability[1].startMinute = 660
        XCTAssertThrowsError(try edited.mergingSettingsDraft(from: original, into: current))
    }

    @MainActor func testStaleDraftPreservesSettingsReceivedBySync() async throws {
        let original = PlannerState()
        let repository = try LocalRepository(inMemory: true)
        try repository.save(original)
        let store = PlannerStore(state: original, repository: repository,
                                 result: ScheduleEngine().generate(state: original, now: Date()))
        var draft = original.settings
        draft.notificationMinute = 1200
        var remote = original
        remote.settings.minimumScheduleUnit = 30
        try repository.save(remote)
        let received = remote
        store.beginCloudSync(operation: {
            SyncOutcome(state: received, ledger: SyncLedger(), sent: 0, received: 1)
        }, snapshot: { (received, SyncLedger()) })
        await store.syncTask?.value
        XCTAssertEqual(store.state.settings.minimumScheduleUnit, 30)

        let saved = await store.saveStudySettings(draft, from: original.settings)

        XCTAssertTrue(saved)
        XCTAssertEqual(store.state.settings.minimumScheduleUnit, 30)
        XCTAssertEqual(store.state.settings.notificationMinute, 1200)
        XCTAssertEqual(try repository.load().settings.minimumScheduleUnit, 30)
    }
}
