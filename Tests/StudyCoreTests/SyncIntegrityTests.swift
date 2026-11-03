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

    func testCompletionCourseMustMatchItsLiveOrDeletedTask() throws {
        for kind in ["live", "deletedDraft", "deletedConfirmed"] {
            var state = try fixture()
            var other = state.courses[0]
            other.id = UUID(); other.name = "Other course"
            state.courses.append(other)
            if kind == "deletedDraft" {
                state.tasks[0].confirmedAt = nil; state.tasks[0].completedMinutes = 0; state.tasks[0].status = .planned
            }
            var ledger = SyncLedger()
            try ledger.capture(state)
            state.completions[0].courseID = other.id
            let completionKey = "completions/" + state.completions[0].id.uuidString
            ledger.records[completionKey]?.payload = try JSONEncoder().encode(state.completions[0])
            if kind != "live" { ledger.records["tasks/" + state.tasks[0].id.uuidString]?.deleted = true }
            let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence
            XCTAssertThrowsError(try ledger.materialize(), kind)
            XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated(), kind)
            XCTAssertThrowsError(try PlannerBackup(state: state, reason: "Mismatched course").validated(), kind)
            XCTAssertEqual(ledger.records, before)
            XCTAssertEqual(ledger.clock, clock)
            XCTAssertEqual(ledger.sequence, sequence)
        }
    }

    func testCaptureRejectsCrossCourseCompletionBeforeAnyMutation() throws {
        for archivedTaskCourse in [false, true] {
            var state = try fixture()
            var other = state.courses[0]
            other.id = UUID(); other.name = "Other course"
            state.courses.append(other)
            var ledger = SyncLedger()
            try ledger.capture(state)
            state.courses[0].isArchived = archivedTaskCourse
            state.completions[0].courseID = other.id
            let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence, input = state
            XCTAssertThrowsError(try ledger.capture(state))
            XCTAssertEqual(ledger.records, before)
            XCTAssertEqual(ledger.clock, clock)
            XCTAssertEqual(ledger.sequence, sequence)
            XCTAssertEqual(state, input)
        }
    }

    func testLegacyCompletionWithoutLiveTaskKeepsItsProgress() throws {
        for hasTombstone in [false, true] {
            let state = try fixture()
            var ledger = SyncLedger()
            try ledger.capture(state)
            let key = "tasks/" + state.tasks[0].id.uuidString
            if hasTombstone { ledger.records[key]?.deleted = true }
            else { ledger.records.removeValue(forKey: key) }
            let restored = try ledger.materialize()
            XCTAssertTrue(restored.tasks.isEmpty)
            XCTAssertEqual(restored.completions, state.completions)
            XCTAssertEqual(restored.completedMinutes(for: restored.courses[0]), 20)
            _ = try CloudArchive(ledger: ledger).validated()
            _ = try PlannerBackup(state: restored, reason: "Legacy history").validated()
        }
    }

    func testNestedMergeRedirectsOfflineConfirmationBeforeCheckingCourseIdentity() throws {
        for replaceDraft in [false, true] {
            var base = try fixture()
            let now = base.tasks[0].start, sourceID = base.courses[0].id, taskID = base.tasks[0].id
            base.completions = []
            base.tasks[0].confirmedAt = nil; base.tasks[0].completedMinutes = 0; base.tasks[0].status = .planned
            let second = Course(name: "B", totalMinutes: 60, startDate: now, deadline: now)
            let third = Course(name: "C", totalMinutes: 60, startDate: now, deadline: now)
            base.courses += [second, third]
            var mac = SyncLedger(), phone = SyncLedger()
            try mac.capture(base, now: now)
            try phone.merge(mac.changes(after: 0))
            var combined = base
            let first = try combined.mergeCourses(ids: [sourceID, second.id], name: "First merge")
            combined.removeArchivedCourses()
            try mac.capture(combined, now: now.addingTimeInterval(1))
            let merged = try combined.mergeCourses(ids: [first.id, third.id], name: "Nested merge")
            combined.removeArchivedCourses()
            if replaceDraft { _ = combined.replan(now: now) }
            try mac.capture(combined, now: now.addingTimeInterval(3))
            var offline = try phone.materialize()
            try offline.confirm(taskID: taskID, actualMinutes: 20, now: now)
            try phone.capture(offline, now: now.addingTimeInterval(2))
            let localRows = mac.changes(after: 0), remoteRows = phone.changes(after: 0)
            try mac.merge(remoteRows); try phone.merge(localRows)
            let restored = try mac.materialize()
            XCTAssertEqual(restored, try phone.materialize())
            XCTAssertEqual(restored.completedMinutes(for: merged), 20)
            XCTAssertEqual(restored.completions[0].courseID, merged.id)
            XCTAssertEqual(restored.tasks.first { $0.id == taskID }?.courseID, merged.id)
            _ = try CloudArchive(ledger: mac).validated()
        }
    }
}
