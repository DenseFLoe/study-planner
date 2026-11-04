import XCTest
import StudyCore
@testable import StudyPersistence

final class FixedEventTransactionTests: XCTestCase {
    func testOccurrenceTransactionRejectsChangedTimeAndNewRestoreConflict() throws {
        let repository = try LocalRepository(inMemory: true), baseline = fixture(), now = Date()
        let event = baseline.fixedEvents[0], day = event.startDate
        var changed = baseline; changed.fixedEvents[0].startMinute += 5
        try repository.save(changed)
        let edit = FixedEventOccurrenceEdit(reviewed: event, on: day, skipped: true)
        let before = try repository.loadLedger().records
        XCTAssertThrowsError(try repository.saveFixedOccurrence(edit, now: now))
        XCTAssertEqual(try repository.loadLedger().records, before)

        var skipped = baseline; skipped.fixedEvents[0].excludedDates = [day]
        let restore = FixedEventOccurrenceEdit(reviewed: skipped.fixedEvents[0], on: day, skipped: false)
        skipped.fixedEvents.append(.init(title: "稍后同步的占用", startMinute: 550, endMinute: 580, startDate: day, endDate: day))
        try repository.save(skipped)
        let records = try repository.loadLedger().records
        XCTAssertThrowsError(try repository.saveFixedOccurrence(restore, now: now))
        XCTAssertEqual(try repository.loadLedger().records, records)
        XCTAssertEqual(try repository.load().fixedEvents.count, 2)
    }

    @MainActor func testInteractiveOccurrenceTransactionUsesFreshMetadata() async throws {
        let repository = try LocalRepository(inMemory: true), baseline = fixture()
        var latest = baseline; latest.fixedEvents[0].notes = "同步新备注"; latest.fixedEvents[0].color = "green"
        try repository.save(latest)
        let edit = FixedEventOccurrenceEdit(reviewed: baseline.fixedEvents[0], on: baseline.fixedEvents[0].startDate, skipped: true)
        let storage: PlannerRepository = repository
        let saved = try await storage.saveFixedOccurrenceForInteraction(edit, from: baseline, now: Date())
        latest.fixedEvents[0].excludedDates = [baseline.fixedEvents[0].startDate]
        XCTAssertEqual(saved.fixedEvents, latest.fixedEvents)
        XCTAssertEqual(try repository.load().fixedEvents, latest.fixedEvents)
    }
    private func fixture() -> PlannerState {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
        var state = PlannerState()
        state.fixedEvents = [FixedEvent(title: "Original", startMinute: 540, endMinute: 600, startDate: day, endDate: day)]
        return state
    }

    func testDisjointNotesPreserveRemoteTimeTitleAndExclusions() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, remote = baseline
        local.fixedEvents[0].notes = "Local notes"
        remote.fixedEvents[0].title = "Phone title"
        remote.fixedEvents[0].startMinute = 600
        remote.fixedEvents[0].endMinute = 660
        remote.fixedEvents[0].excludedDates = [remote.fixedEvents[0].startDate]
        try repository.save(remote)
        let saved = try repository.saveChanges(local, from: baseline)
        remote.fixedEvents[0].notes = "Local notes"
        XCTAssertEqual(saved.fixedEvents, remote.fixedEvents)
        XCTAssertEqual(try repository.loadLedger().materialize().fixedEvents, saved.fixedEvents)
    }

    func testSameFieldConflictRejectsAllChanges() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, remote = baseline
        local.fixedEvents[0].title = "Mac title"
        local.settings.notificationMinute = 1234
        remote.fixedEvents[0].title = "Phone title"
        try repository.save(remote)
        let ledger = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveChanges(local, from: baseline))
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, ledger.records)
    }

    func testTimeAndExclusionsAreOneSchedulingGroup() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, remote = baseline
        local.fixedEvents[0].startMinute = 570
        remote.fixedEvents[0].excludedDates = [remote.fixedEvents[0].startDate]
        try repository.save(remote)
        XCTAssertThrowsError(try repository.saveChanges(local, from: baseline))
        XCTAssertEqual(try repository.load(), remote)
    }

    func testDeletionCannotBeRevivedButExplicitRestoreAndSameValueRemainAllowed() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var local = baseline, removed = baseline
        local.fixedEvents[0].notes = "Local notes"
        try repository.save(local)
        XCTAssertEqual(try repository.saveChanges(local, from: baseline).fixedEvents, local.fixedEvents)
        removed.fixedEvents = []
        try repository.save(removed)
        let ledger = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveChanges(local, from: baseline))
        XCTAssertEqual(try repository.loadLedger().records, ledger.records)
        XCTAssertTrue(try repository.load().fixedEvents.isEmpty)
        XCTAssertEqual(try repository.saveChanges(local, from: removed).fixedEvents, local.fixedEvents)
    }

    func testFinalEventTransactionRebasesBeforeSplittingHistory() throws {
        let repository = try LocalRepository(inMemory: true)
        let calendar = Calendar.current, now = Date()
        let today = calendar.startOfDay(for: now)
        var baseline = fixture()
        baseline.fixedEvents[0].startDate = calendar.date(byAdding: .day, value: -2, to: today)!
        baseline.fixedEvents[0].weekdays = Set(1...7)
        try repository.save(baseline)
        var draft = baseline.fixedEvents[0]
        draft.notes = "Local notes"
        let edit = FixedEventEdit(event: draft, baseline: baseline.fixedEvents[0])
        var prepared = baseline
        try edit.apply(to: &prepared, now: now)
        XCTAssertEqual(prepared.fixedEvents.count, 2)
        var remote = baseline
        remote.fixedEvents[0].title = "Phone title"
        remote.fixedEvents[0].startMinute = 480
        remote.fixedEvents[0].excludedDates = [remote.fixedEvents[0].endDate]
        try repository.save(remote)
        let saved = try repository.saveFixedEvent(edit, now: now)
        XCTAssertEqual(saved.fixedEvents.count, 2)
        XCTAssertTrue(saved.fixedEvents.allSatisfy { $0.title == "Phone title" && $0.startMinute == 480 })
        let future = try XCTUnwrap(saved.fixedEvents.first { $0.id != draft.id })
        XCTAssertEqual(future.notes, "Local notes")
        XCTAssertEqual(future.excludedDates, remote.fixedEvents[0].excludedDates)
        XCTAssertEqual(Set(try repository.loadLedger().materialize().fixedEvents.map(\.id)), Set(saved.fixedEvents.map(\.id)))
        // Generic snapshot commits cannot safely rebase a dependent split row.
        try repository.save(remote)
        XCTAssertThrowsError(try repository.saveChanges(prepared, from: baseline))
    }

    func testDeletionAfterPreparationLeavesNoSplitRuleOrSkips() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var draft = baseline.fixedEvents[0]; draft.notes = "Local notes"
        let edit = FixedEventEdit(event: draft, baseline: baseline.fixedEvents[0])
        var prepared = baseline
        try edit.apply(to: &prepared, now: Date())
        var deleted = baseline; deleted.fixedEvents = []
        try repository.save(deleted)
        let ledger = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveFixedEvent(edit)) { XCTAssertTrue($0 is FixedEventEditError) }
        XCTAssertEqual(try repository.load(), deleted)
        XCTAssertEqual(try repository.loadLedger().records, ledger.records)
    }

    func testConflictReviewIsRevalidatedAtTransactionBoundary() throws {
        let repository = try LocalRepository(inMemory: true)
        let baseline = fixture()
        try repository.save(baseline)
        var incoming = baseline.fixedEvents[0]; incoming.id = UUID()
        var probe = baseline
        var conflicts: [FixedEventConflict] = []
        do { try probe.updateFixedEvent(incoming, now: Date()) }
        catch let PlannerError.fixedConflict(found) { conflicts = found }
        XCTAssertFalse(conflicts.isEmpty)
        let edit = FixedEventEdit(event: incoming, baseline: nil, skippingExistingDates: [incoming.startDate], reviewedConflicts: conflicts)
        var prepared = baseline
        try edit.apply(to: &prepared, now: Date())
        var remote = baseline
        remote.fixedEvents[0].startMinute += 10
        try repository.save(remote)
        let ledger = try repository.loadLedger()
        XCTAssertThrowsError(try repository.saveFixedEvent(edit))
        XCTAssertEqual(try repository.load(), remote)
        XCTAssertEqual(try repository.loadLedger().records, ledger.records)
    }

    func testDeletionDuringOptimisticCalculationRetriesAndRejectsWithoutRevival() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixed-retry.store")
        let repository = try LocalRepository(url: url)
        let baseline = fixture()
        try repository.save(baseline)
        var draft = baseline.fixedEvents[0]; draft.notes = "Local notes"
        let edit = FixedEventEdit(event: draft, baseline: baseline.fixedEvents[0])
        var attempts = 0
        XCTAssertThrowsError(try repository.update { state, _ in
            attempts += 1
            try edit.apply(to: &state, now: Date())
            _ = state.replan(now: Date())
            if attempts == 1 {
                var deleted = baseline; deleted.fixedEvents = []
                try LocalRepository.withExclusiveAccess { try LocalRepository(url: url).save(deleted) }
            }
        }) { XCTAssertTrue($0 is FixedEventEditError) }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(try LocalRepository(url: url).load().fixedEvents.isEmpty)
        XCTAssertTrue(try LocalRepository(url: url).loadLedger().records["fixedEvents/" + draft.id.uuidString]?.deleted == true)
    }
}
