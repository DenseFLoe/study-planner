import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class EventConflictSaveTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }

    @MainActor func testLocalSkipPersistsAndFailedWriteLeavesStateAndPlanUnchanged() async throws {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let local = FixedEvent(title: "本地固定课", startMinute: 540, endMinute: 600, startDate: day, endDate: day)
        let incoming = FixedEvent(title: "植入课", startMinute: 570, endMinute: 630, startDate: day, endDate: day)
        var original = PlannerState()
        original.fixedEvents = [local]
        let plan = original.replan(now: Date())
        let repo = Repository()
        let store = PlannerStore(state: original, repository: repo, result: plan)
        XCTAssertFalse(store.saveEvent(incoming))
        XCTAssertEqual(store.pendingEventConflicts?.map(\.eventID), [local.id])
        XCTAssertNil(repo.saved)
        repo.fails = true
        XCTAssertFalse(store.saveEvent(incoming, skippingDates: [], skippingExistingDates: [day]))
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(store.result.tasks, plan.tasks)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(repo.saved)
        repo.fails = false
        XCTAssertTrue(store.saveEvent(incoming, skippingDates: [], skippingExistingDates: [day]))
        XCTAssertEqual(repo.saved, store.state)
        XCTAssertFalse(store.state.fixedEvents.first { $0.id == local.id }!.occurs(on: day, calendar: cal))
        XCTAssertTrue(store.state.fixedEvents.first { $0.id == incoming.id }!.occurs(on: day, calendar: cal))
        XCTAssertNil(store.pendingEventConflicts)
        XCTAssertNil(store.errorMessage)
        // Restoring a skipped local occurrence must still detect the new occupant.
        XCTAssertThrowsError(try originalRestoring(store.state, local: local, day: day, calendar: cal))
    }

    private func originalRestoring(_ state: PlannerState, local: FixedEvent, day: Date, calendar: Calendar) throws {
        var copy = state
        try copy.setFixedEventSkipped(id: local.id, on: day, skipped: false, now: Date(), calendar: calendar)
    }
}
