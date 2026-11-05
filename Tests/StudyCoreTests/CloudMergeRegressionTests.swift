import XCTest
@testable import StudyCore

final class CloudMergeRegressionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_793_880_000)
    func fixture() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 0, endMinute: 1440) }
        state.courses = [Course(name: "Synthetic", totalMinutes: 120, startDate: now.addingTimeInterval(-7 * 86400), deadline: now.addingTimeInterval(30 * 86400))]
        return state
    }
    func testOfflineDeadlineEditPreservesNewerLessonStructure() throws {
        let base = fixture(); var common = SyncLedger(); try common.capture(base, now: now.addingTimeInterval(-100))
        var a = common, b = common, local = base, phone = base; a.device = "mac"; b.device = "phone"
        local.courses[0].totalMinutes = 60
        local.courses[0].deletedLessonIDs = ["removed-lesson"]
        try a.capture(local, now: now.addingTimeInterval(-50))
        phone.courses[0].deadline = now.addingTimeInterval(25 * 86400)
        try b.capture(phone, now: now.addingTimeInterval(-10))
        var left = a, right = b
        try left.merge(b.changes(after: 0)); try right.merge(a.changes(after: 0))
        let result = try left.materialize().courses[0]
        XCTAssertEqual(result.totalMinutes, 60)
        XCTAssertEqual(result.deletedLessonIDs, ["removed-lesson"])
        XCTAssertEqual(result.deadline, phone.courses[0].deadline)
        XCTAssertEqual(try left.materialize(), try right.materialize())
        let sequence = left.sequence
        try left.merge(right.changes(after: 0)); try left.capture(left.materialize(), now: now)
        XCTAssertEqual(left.sequence, sequence, "a converged merge must not create an upload loop")
        // Verify the old row-only server also accepts the combined payload.
        let key = "courses/" + result.id.uuidString
        XCTAssertTrue(try XCTUnwrap(left.records[key]).wins(over: XCTUnwrap(b.records[key])))
    }
    func testLegacyCourseGetsFieldBaselineOnFirstEdit() throws {
        var base = fixture(), a = SyncLedger(); try a.capture(base, now: now.addingTimeInterval(-100))
        for key in a.records.keys { a.records[key]?.fieldVersions = nil }
        var b = a
        base.courses[0].totalMinutes = 60; try a.capture(base, now: now.addingTimeInterval(-50))
        var phone = try b.materialize(); phone.courses[0].notes = "Phone note"
        try b.capture(phone, now: now)
        try a.merge(b.changes(after: 0))
        XCTAssertEqual(try a.materialize().courses[0].totalMinutes, 60)
        XCTAssertEqual(try a.materialize().courses[0].notes, "Phone note")
    }
    func testCourseOptionalRemovalAndStructuralGroupRemainAtomic() throws {
        var base = fixture(); base.courses[0].dailyStudyWeight = 2
        var a = SyncLedger(); try a.capture(base, now: now.addingTimeInterval(-100)); var b = a
        var local = base; local.courses[0].dailyStudyWeight = nil; local.courses[0].name = "Mac name"
        try a.capture(local, now: now.addingTimeInterval(-10))
        var phone = base; phone.courses[0].color = "red"
        try b.capture(phone, now: now)
        try a.merge(b.changes(after: 0))
        let result = try a.materialize().courses[0]
        XCTAssertNil(result.dailyStudyWeight); XCTAssertEqual(result.name, "Mac name"); XCTAssertEqual(result.color, "red")
    }
    func testCloudDropsObsoleteUnconfirmedHistoryButKeepsOfflineConfirmation() throws {
        let base = fixture(); var common = SyncLedger(); try common.capture(base, now: now.addingTimeInterval(-4 * 86400))
        var a = common, b = common, local = base, phone = base; a.device = "mac"; b.device = "phone"
        let future = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(86400), durationMinutes: 60)
        let obsolete = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(-3 * 86400), durationMinutes: 60)
        var studied = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(-2 * 86400), durationMinutes: 60)
        studied.confirmedAt = now.addingTimeInterval(-60); studied.completedMinutes = 60; studied.status = .completed
        local.tasks = [future]; try a.capture(local, now: now.addingTimeInterval(-3600))
        phone.tasks = [obsolete]; try b.capture(phone, now: now.addingTimeInterval(-3 * 86400))
        phone.tasks.append(studied); phone.courses[0].notes = "Recent phone edit"
        try b.capture(phone, now: now.addingTimeInterval(-60))
        try a.mergeCloudSnapshot(b, now: now)
        let result = try a.materialize()
        XCTAssertFalse(result.tasks.contains { $0.id == obsolete.id })
        XCTAssertTrue(result.tasks.contains { $0.id == studied.id && $0.completedMinutes == 60 })
        XCTAssertTrue(result.tasks.contains { $0.id == future.id })
        XCTAssertTrue(result.confirmationCandidates(at: now).isEmpty)
        XCTAssertEqual(a.records["tasks/" + obsolete.id.uuidString]?.deleted, true)
        var peer = b; try peer.merge(a.changes(after: 0))
        XCTAssertFalse(try peer.materialize().tasks.contains { $0.id == obsolete.id })
    }
    func testOpaqueLegacyTombstoneDoesNotBlockAnUnrelatedNewPlan() throws {
        let base = fixture(); var a = SyncLedger(); try a.capture(base, now: now.addingTimeInterval(-100))
        var b = a, remote = base
        let old = SyncRecord(kind: "tasks", id: UUID().uuidString, payload: Data("opaque legacy deletion".utf8), deleted: true, version: 1, device: "legacy", sequence: 1)
        try a.merge([old])
        let history = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(-86400), durationMinutes: 60)
        remote.tasks = [history]; try b.capture(remote, now: now)
        try a.mergeCloudSnapshot(b, now: now)
        XCTAssertTrue(try a.materialize().tasks.contains { $0.id == history.id })
    }
    func testConflictingPayloadForIdenticalFieldRevisionIsRejected() throws {
        let base = fixture(); var ledger = SyncLedger(); try ledger.capture(base, now: now)
        let key = "courses/" + base.courses[0].id.uuidString
        var row = try XCTUnwrap(ledger.records[key]); var course = base.courses[0]; course.name = "Invalid reused revision"
        row.payload = try JSONEncoder().encode(course)
        XCTAssertThrowsError(try ledger.merge([row]))
        XCTAssertEqual(try ledger.materialize().courses[0].name, base.courses[0].name)
    }
    func testNewerPlanRetainsItsGenuinePendingHistory() throws {
        let base = fixture(); var a = SyncLedger(); try a.capture(base, now: now.addingTimeInterval(-100))
        var b = a, phone = base
        let history = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(-86400), durationMinutes: 60)
        phone.tasks = [history]; try b.capture(phone, now: now.addingTimeInterval(-10))
        try a.mergeCloudSnapshot(b, now: now)
        XCTAssertTrue(try a.materialize().tasks.contains { $0.id == history.id })
    }
    func testConfirmationDoesNotConflictWithTheSamePendingPlan() throws {
        var base = fixture()
        let studied = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(-3600), durationMinutes: 60)
        let future = ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(86400), durationMinutes: 60)
        base.tasks = [studied, future]
        var common = SyncLedger(); try common.capture(base, now: now.addingTimeInterval(-7200))
        var confirmed = common, edited = base
        try edited.confirm(taskID: studied.id, actualMinutes: 60, now: now)
        try confirmed.capture(edited, now: now)
        for (var local, remote) in [(confirmed, common), (common, confirmed)] {
            try local.mergeCloudSnapshot(remote, now: now)
            let result = try local.materialize()
            XCTAssertEqual(result.completions.count, 1)
            XCTAssertTrue(result.tasks.contains { $0.id == studied.id && !$0.isUnconfirmed })
            XCTAssertTrue(result.tasks.contains { $0.id == future.id && $0.isUnconfirmed })
            let sequence = local.sequence
            try local.mergeCloudSnapshot(remote, now: now)
            XCTAssertEqual(local.sequence, sequence)
        }
        var undone = confirmed, undoState = edited
        try undoState.undoConfirmation(taskID: studied.id, now: now.addingTimeInterval(60))
        try undone.capture(undoState, now: now.addingTimeInterval(60))
        for (var local, remote) in [(undone, confirmed), (confirmed, undone)] {
            try local.mergeCloudSnapshot(remote, now: now.addingTimeInterval(60))
            let result = try local.materialize()
            XCTAssertTrue(result.completions.isEmpty)
            XCTAssertTrue(result.tasks.contains { $0.id == studied.id && $0.isUnconfirmed })
            XCTAssertTrue(result.tasks.contains { $0.id == future.id && $0.isUnconfirmed })
        }
    }
    func testDifferentPlansWithSameRevisionRemainRejectedAtomically() throws {
        var base = fixture()
        base.tasks = [ScheduledTask(courseID: base.courses[0].id, start: now.addingTimeInterval(86400), durationMinutes: 60)]
        var a = SyncLedger(); a.device = "same-plan-source"; try a.capture(base, now: now)
        base.tasks[0].id = UUID()
        var b = SyncLedger(); b.device = a.device; try b.capture(base, now: now)
        let before = a.records, sequence = a.sequence
        XCTAssertThrowsError(try a.mergeCloudSnapshot(b, now: now))
        XCTAssertEqual(a.records, before)
        XCTAssertEqual(a.sequence, sequence)
    }
}
