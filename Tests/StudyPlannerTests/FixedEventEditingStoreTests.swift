import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class FixedEventEditingStoreTests: XCTestCase {
    private final class RacingRepository: PlannerRepository {
        let local: LocalRepository
        var incoming: PlannerState?
        init(_ state: PlannerState) throws {
            local = try LocalRepository(inMemory: true)
            try local.save(state)
        }
        func load() throws -> PlannerState { try local.load() }
        func save(_ state: PlannerState) throws { try local.save(state) }
        @MainActor func saveFixedEventForInteraction(_ edit: FixedEventEdit,
                                                    from baseline: PlannerState, now: Date) async throws -> PlannerState {
            if let incoming { try local.save(incoming) }
            return try await local.saveFixedEventForInteraction(edit, from: baseline, now: now)
        }
    }
    private func fixture() -> PlannerState {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: Date()))!
        var state = PlannerState()
        state.fixedEvents = [FixedEvent(title: "Original", startMinute: 540, endMinute: 600, startDate: day, endDate: day)]
        return state
    }

    @MainActor func testOldEditorPreservesRemoteInputsInPublishedAndPersistedState() async throws {
        let baseline = fixture()
        var remote = baseline
        remote.fixedEvents[0].title = "Phone title"; remote.fixedEvents[0].startMinute = 600
        remote.fixedEvents[0].endMinute = 660; remote.fixedEvents[0].excludedDates = [remote.fixedEvents[0].startDate]
        let repo = try RacingRepository(remote)
        let store = PlannerStore(state: remote, repository: repo, result: ScheduleEngine().assessSavedPlan(state: remote, now: Date()))
        var draft = baseline.fixedEvents[0]; draft.notes = "Local notes"
        let saved = await store.saveEvent(draft, from: baseline.fixedEvents[0])
        XCTAssertTrue(saved)
        remote.fixedEvents[0].notes = draft.notes
        XCTAssertEqual(store.state.fixedEvents, remote.fixedEvents)
        XCTAssertEqual(try repo.load().fixedEvents, store.state.fixedEvents)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor func testSyncBetweenPreparationAndWriteIsMergedOrRejectedAtomically() async throws {
        for scenario in 0..<3 {
            let baseline = fixture()
            let repo = try RacingRepository(baseline)
            let store = PlannerStore(state: baseline, repository: repo, result: ScheduleEngine().assessSavedPlan(state: baseline, now: Date()))
            var draft = baseline.fixedEvents[0]; draft.notes = "Mac notes"
            var remote = baseline
            if scenario == 0 { remote.fixedEvents[0].title = "Phone title" }
            if scenario == 1 { remote.fixedEvents[0].notes = "Phone notes" }
            if scenario == 2 { remote.fixedEvents = [] }
            repo.incoming = remote
            let saved = await store.saveEvent(draft, from: baseline.fixedEvents[0])
            XCTAssertEqual(saved, scenario == 0)
            if scenario == 0 {
                XCTAssertEqual(store.state.fixedEvents[0].title, "Phone title")
                XCTAssertEqual(store.state.fixedEvents[0].notes, "Mac notes")
                XCTAssertEqual(try repo.load().fixedEvents, store.state.fixedEvents)
            } else {
                XCTAssertEqual(try repo.load(), remote)
                // Conflicts refresh the visible store to the committed remote
                // state, while the editor retains its rejected local draft.
                XCTAssertEqual(store.state, remote)
                XCTAssertNotNil(store.errorMessage)
                XCTAssertNil(store.pendingEventConflicts)
                XCTAssertEqual(draft.notes, "Mac notes")
                XCTAssertFalse(store.orderSaveBusy)
                if scenario == 1 {
                    // Reconfirming against that latest baseline may explicitly
                    // replace the conflicting notes; the first attempt must not.
                    repo.incoming = nil
                    let retry = await store.saveEvent(draft, from: remote.fixedEvents[0])
                    XCTAssertTrue(retry)
                    XCTAssertEqual(store.state.fixedEvents[0].notes, "Mac notes")
                    XCTAssertEqual(try repo.load(), store.state)
                    XCTAssertNil(store.errorMessage)
                }
            }
        }
    }

    @MainActor func testReviewRefreshDoesNotApplyOldChoicesAndCanBeConfirmedAgain() async throws {
        let baseline = fixture()
        let repo = try RacingRepository(baseline)
        let store = PlannerStore(state: baseline, repository: repo, result: ScheduleEngine().assessSavedPlan(state: baseline, now: Date()))
        var incoming = baseline.fixedEvents[0]; incoming.id = UUID()
        let initial = await store.saveEvent(incoming)
        XCTAssertFalse(initial)
        let reviewed = try XCTUnwrap(store.pendingEventConflicts)
        var remote = baseline; remote.fixedEvents[0].title = "New phone name"
        repo.incoming = remote
        let outdated = await store.saveEvent(incoming, skippingExistingDates: [incoming.startDate], reviewedConflicts: reviewed)
        XCTAssertFalse(outdated)
        XCTAssertEqual(try repo.load(), remote)
        let updated = try XCTUnwrap(store.pendingEventConflicts)
        XCTAssertEqual(updated.first?.title, "New phone name")
        // The UI still has its old store snapshot; a refreshed review must be
        // checked against the latest repository state on its next attempt.
        let saved = await store.saveEvent(incoming, skippingExistingDates: [incoming.startDate], reviewedConflicts: updated)
        XCTAssertTrue(saved)
        XCTAssertEqual(store.state.fixedEvents.count, 2)
        XCTAssertEqual(store.state.fixedEvents.first { $0.id == baseline.fixedEvents[0].id }?.excludedDates, [incoming.startDate])
    }
}
