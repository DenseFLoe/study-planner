import XCTest
@testable import StudyCore

final class ProgressIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fixture(_ minutes: [Int], baseline: Int = 0) -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "Progress fixture", totalMinutes: 120, startDate: now, deadline: now)
        course.initialCompletedMinutes = baseline
        state.courses = [course]
        state.completions = minutes.map { amount in
            let taskID = UUID()
            return CompletionRecord(id: stablePlannerID("completion|" + taskID.uuidString),
                courseID: course.id, taskID: taskID, minutes: amount, recordedAt: now)
        }
        return state
    }

    // Model external rows without using the capture validator under test.
    private func wire(_ state: PlannerState) throws -> SyncLedger {
        var ledger = SyncLedger()
        try ledger.capture(PlannerState())
        func row<T: Encodable>(_ kind: String, _ id: UUID, _ value: T) throws -> SyncRecord {
            SyncRecord(kind: kind, id: id.uuidString, payload: try JSONEncoder().encode(value),
                deleted: false, version: 1, device: "progress-fixture", sequence: 1)
        }
        for value in state.courses { let item = try row("courses", value.id, value); ledger.records[item.key] = item }
        for value in state.tasks { let item = try row("tasks", value.id, value); ledger.records[item.key] = item }
        for value in state.completions { let item = try row("completions", value.id, value); ledger.records[item.key] = item }
        return ledger
    }

    func testCaptureRejectsProgressOverflowWithoutMutation() throws {
        for state in [fixture([Int.max, 1]), fixture([1], baseline: Int.max)] {
            var ledger = SyncLedger()
            try ledger.capture(fixture([20]))
            let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence, input = state
            XCTAssertThrowsError(try ledger.capture(state))
            XCTAssertEqual(ledger.records, before)
            XCTAssertEqual(ledger.clock, clock)
            XCTAssertEqual(ledger.sequence, sequence)
            XCTAssertEqual(state, input)
        }
    }

    func testMaterializeAndArchiveRejectProgressOverflowWithoutMutation() throws {
        for state in [fixture([Int.max, 1]), fixture([1], baseline: Int.max)] {
            let ledger = try wire(state), before = ledger.records
            XCTAssertThrowsError(try ledger.materialize())
            XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
            XCTAssertEqual(ledger.records, before)
        }
    }

    func testRepresentableLegacyProgressKeepsExistingSemantics() throws {
        for state in [fixture([Int.max]), fixture([Int.max - 1, 1]), fixture([1], baseline: Int.max - 1),
                      fixture([Int.max], baseline: Int.min), fixture([1441])] {
            var ledger = SyncLedger()
            try ledger.capture(state)
            let restored = try ledger.materialize()
            XCTAssertEqual(restored.completions.count, state.completions.count)
            XCTAssertEqual(restored.completedMinutes(for: restored.courses[0]), 120)
            _ = try CloudArchive(ledger: ledger).validated()
        }
    }

    private func withBaseline(_ value: Int, sourceID: UUID, in course: Course) -> Course {
        var result = course
        if result.id == sourceID { result.initialCompletedMinutes = value }
        result.mergedSources = result.mergedSources?.map { withBaseline(value, sourceID: sourceID, in: $0) }
        return result
    }

    private func nested(baseline: Int, route: String = "target") throws -> PlannerState {
        var state = fixture([])
        let source = state.courses[0]
        let second = Course(name: "B", totalMinutes: 120, startDate: now, deadline: now)
        let third = Course(name: "C", totalMinutes: 120, startDate: now, deadline: now)
        state.courses += [second, third]
        let task = ScheduledTask(courseID: source.id, start: now, durationMinutes: 60)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 1, now: now)
        let first = try state.mergeCourses(ids: [source.id, second.id], name: "First merge")
        _ = try state.mergeCourses(ids: [first.id, third.id], name: "Nested merge")
        state.removeArchivedCourses()
        state.courses[0] = withBaseline(baseline, sourceID: source.id, in: state.courses[0])
        if route == "sibling" { state.tasks[0].lessonID = first.id.uuidString + "/" + second.id.uuidString + "/whole" }
        if route == "outer" { state.tasks[0].lessonID = third.id.uuidString + "/whole" }
        if route == "orphan" { state.tasks = [] }
        return state
    }

    func testNestedMergedSourceOverflowIsCheckedDespiteNormalParentBaseline() throws {
        let state = try nested(baseline: Int.max)
        XCTAssertEqual(state.courses[0].initialCompletedMinutes, 0)
        var ledger = SyncLedger()
        XCTAssertThrowsError(try ledger.capture(state))
        XCTAssertTrue(ledger.records.isEmpty)
        let imported = try wire(state)
        XCTAssertThrowsError(try imported.materialize())
        XCTAssertThrowsError(try CloudArchive(ledger: imported).validated())
    }

    func testNestedProgressUsesOnlyEachSourcesAssociatedTaskPrefix() throws {
        for route in ["target", "sibling", "outer", "orphan"] {
            let state = try nested(baseline: route == "target" ? Int.max - 1 : Int.max, route: route)
            var ledger = SyncLedger()
            try ledger.capture(state)
            let restored = try ledger.materialize()
            XCTAssertEqual(restored.completions.count, 1)
            XCTAssertEqual(restored.completedMinutes(for: restored.courses[0]), route == "sibling" || route == "outer" ? 121 : 120)
            _ = try CloudArchive(ledger: ledger).validated()
        }
    }

    func testDiscardedHistoryDoesNotCountTowardCurrentProgress() throws {
        var state = fixture([Int.max, 1])
        state.courses[0].isArchived = true
        var archived = SyncLedger()
        try archived.capture(state)
        XCTAssertTrue(try archived.materialize().completions.isEmpty)
        var ledger = try wire(fixture([Int.max, 1]))
        for key in ledger.records.keys where ledger.records[key]?.kind == "completions" { ledger.records[key]?.deleted = true }
        XCTAssertTrue(try ledger.materialize().completions.isEmpty)
        _ = try CloudArchive(ledger: ledger).validated()
    }
}
