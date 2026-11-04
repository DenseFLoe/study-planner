import XCTest
@testable import StudyCore

final class LegacyConfirmationIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fixture(minutes: Int, canonical: Int? = nil) -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "Legacy confirmation", totalMinutes: 120, startDate: now, deadline: now)
        state.courses = [course]
        var task = ScheduledTask(courseID: course.id, start: now, durationMinutes: 60,
            status: minutes == 0 ? .missed : minutes == 60 ? .completed : .partial)
        task.confirmedAt = now; task.completedMinutes = minutes
        state.tasks = [task]
        if let canonical {
            state.completions = [CompletionRecord(id: stablePlannerID("completion|" + task.id.uuidString),
                courseID: course.id, taskID: task.id, minutes: canonical, recordedAt: now)]
        }
        return state
    }

    private func archivedState(_ ledger: SyncLedger) throws -> PlannerState {
        let data = try JSONEncoder().encode(CloudArchive(ledger: ledger))
        let archive = try JSONDecoder().decode(CloudArchive.self, from: data).validated()
        var imported = SyncLedger()
        try imported.merge(archive.records)
        return try imported.materialize()
    }

    func testInvalidLegacyCreditRejectsBeforeProducingACompletion() throws {
        for minutes in [61, -1] {
            var ledger = SyncLedger()
            try ledger.capture(fixture(minutes: minutes))
            let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence
            XCTAssertThrowsError(try ledger.materialize())
            XCTAssertThrowsError(try archivedState(ledger))
            XCTAssertEqual(ledger.records, before)
            XCTAssertEqual(ledger.clock, clock)
            XCTAssertEqual(ledger.sequence, sequence)
        }
    }

    func testValidLegacyConfirmationsRemainReadableAcrossCaptureAndArchive() throws {
        for minutes in [0, 20, 60] {
            var ledger = SyncLedger()
            try ledger.capture(fixture(minutes: minutes))
            let first = try ledger.materialize()
            XCTAssertEqual(first.completions.count, 1)
            XCTAssertEqual(first.completions[0].minutes, minutes)
            XCTAssertEqual(first.completedMinutes(for: first.courses[0]), minutes)
            XCTAssertEqual(try archivedState(ledger), first)
            try ledger.capture(first)
            let second = try ledger.materialize()
            XCTAssertEqual(second, first)
            XCTAssertEqual(try archivedState(ledger), first)
            let sequence = ledger.sequence
            try ledger.capture(second)
            XCTAssertEqual(ledger.sequence, sequence)
        }
    }

    func testCanonicalRecordAndUndoStillOwnConfirmationState() throws {
        for oldMinutes in [61, -1] {
            let state = fixture(minutes: oldMinutes, canonical: 20)
            var ledger = SyncLedger()
            try ledger.capture(state)
            let confirmed = try ledger.materialize()
            XCTAssertEqual(confirmed.tasks[0].completedMinutes, 20)
            XCTAssertEqual(confirmed.completedMinutes(for: confirmed.courses[0]), 20)
            _ = try archivedState(ledger)
            ledger.records["completions/" + state.completions[0].id.uuidString]?.deleted = true
            let undone = try ledger.materialize()
            XCTAssertNil(undone.tasks[0].confirmedAt)
            XCTAssertEqual(undone.tasks[0].completedMinutes, 0)
            XCTAssertTrue(undone.completions.isEmpty)
            XCTAssertEqual(try archivedState(ledger), undone)
        }
    }

    func testRemovedConfirmedTaskDoesNotBackfillItsHistoricalCredit() throws {
        for referenced in [false, true] {
            let state = fixture(minutes: 61, canonical: referenced ? 20 : nil)
            var ledger = SyncLedger()
            try ledger.capture(state)
            ledger.records["tasks/" + state.tasks[0].id.uuidString]?.deleted = true
            let restored = try ledger.materialize()
            XCTAssertTrue(restored.tasks.isEmpty)
            XCTAssertEqual(restored.completions.count, referenced ? 1 : 0)
            XCTAssertEqual(restored.completedMinutes(for: restored.courses[0]), referenced ? 20 : 0)
            XCTAssertEqual(try archivedState(ledger), restored)
        }
    }
}
