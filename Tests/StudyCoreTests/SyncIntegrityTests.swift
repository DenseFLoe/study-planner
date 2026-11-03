import XCTest
@testable import StudyCore

final class SyncIntegrityTests: XCTestCase {
    private func fixture() throws -> PlannerState {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var state = PlannerState()
        state.courses = [Course(name: "Integrity fixture", totalMinutes: 120, startDate: now, deadline: now)]
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        return state
    }

    func testCaptureRejectsDuplicateTaskConfirmationsWithoutChangingLedger() throws {
        var state = try fixture(), ledger = SyncLedger()
        try ledger.capture(state)
        let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence
        var duplicate = state.completions[0]
        duplicate.id = UUID(); duplicate.minutes = 30
        state.completions.append(duplicate)
        XCTAssertThrowsError(try ledger.capture(state))
        XCTAssertEqual(ledger.records, before)
        XCTAssertEqual(ledger.clock, clock)
        XCTAssertEqual(ledger.sequence, sequence)
    }

    func testWireAndArchiveRejectDuplicateTaskConfirmations() throws {
        let state = try fixture()
        var ledger = SyncLedger()
        try ledger.capture(state)
        var duplicate = state.completions[0]
        duplicate.id = UUID(); duplicate.minutes = 30
        let row = SyncRecord(kind: "completions", id: duplicate.id.uuidString,
            payload: try JSONEncoder().encode(duplicate), deleted: false, version: 1,
            device: "integrity-peer", sequence: 1)
        try ledger.merge([row])
        let before = ledger.records
        XCTAssertThrowsError(try ledger.materialize())
        XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
        XCTAssertEqual(ledger.records, before)

        // A deleted legacy record is not a second active confirmation.
        var tombstone = row
        tombstone.deleted = true; tombstone.version = 2
        try ledger.merge([tombstone])
        XCTAssertEqual(try ledger.materialize().completions.count, 1)
    }

    func testSingleLegacyCompletionIDIsStillAccepted() throws {
        let state = try fixture()
        var ledger = SyncLedger()
        try ledger.capture(state)
        let canonicalKey = "completions/" + state.completions[0].id.uuidString
        var row = try XCTUnwrap(ledger.records.removeValue(forKey: canonicalKey))
        var legacy = state.completions[0]
        legacy.id = UUID()
        row.id = legacy.id.uuidString; row.payload = try JSONEncoder().encode(legacy)
        try ledger.merge([row])
        let restored = try ledger.materialize()
        XCTAssertEqual(restored.completions, [legacy])
        XCTAssertEqual(restored.tasks[0].completedMinutes, 20)
    }

    func testReferencedTaskTombstoneMustMatchItsPayloadIdentity() throws {
        var state = try fixture()
        var other = state.tasks[0]
        other.id = UUID(); other.confirmedAt = nil; other.completedMinutes = 0; other.status = .planned
        state.tasks.append(other)
        var ledger = SyncLedger()
        try ledger.capture(state)
        let key = "tasks/" + state.tasks[0].id.uuidString
        var tombstone = try XCTUnwrap(ledger.records[key])
        var wrongTask = other
        wrongTask.id = UUID()
        tombstone.payload = try JSONEncoder().encode(wrongTask)
        tombstone.deleted = true
        ledger.records[key] = tombstone
        let before = ledger.records
        XCTAssertThrowsError(try ledger.materialize())
        XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
        XCTAssertEqual(ledger.records, before)
    }

    func testUnreferencedTaskTombstoneDoesNotRestoreItsPayload() throws {
        let state = try fixture()
        var ledger = SyncLedger()
        try ledger.capture(state)
        var historical = try XCTUnwrap(ledger.records["tasks/" + state.tasks[0].id.uuidString])
        historical.id = UUID().uuidString; historical.deleted = true
        try ledger.merge([historical])
        XCTAssertEqual(try ledger.materialize().tasks, state.tasks)
        XCTAssertEqual(try ledger.materialize().completions, state.completions)
    }
}
