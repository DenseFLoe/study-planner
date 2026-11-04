import XCTest
import StudyCore
@testable import StudyPersistence

final class SettingsTransactionTests: XCTestCase {
    @MainActor func testSyncBetweenDraftValidationAndCommitPreservesDisjointChange() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = PlannerState()
        try repository.save(baseline)
        var edited = baseline, remote = baseline
        edited.settings.notificationMinute = 1200
        remote.settings.minimumScheduleUnit = 30
        try repository.save(remote)
        let result = try repository.saveChanges(edited, from: baseline)
        XCTAssertEqual(result.settings.minimumScheduleUnit, 30)
        XCTAssertEqual(result.settings.notificationMinute, 1200)
        XCTAssertEqual(try repository.loadLedger().materialize().settings, result.settings)
    }

    @MainActor func testSyncBetweenDraftValidationAndCommitRejectsConflictingChangeAtomically() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = PlannerState()
        try repository.save(baseline)
        var edited = baseline, remote = baseline
        edited.settings.minimumScheduleUnit = 45
        edited.settings.notificationMinute = 1200
        remote.settings.minimumScheduleUnit = 30
        try repository.save(remote)
        let ledger = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveChanges(edited, from: baseline)) { error in
            XCTAssertTrue(error is SettingsEditError)
        }
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, ledger.records)
    }
}
