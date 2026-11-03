import XCTest
@testable import StudyCore

final class SyncTaskIntervalTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func fixture() throws -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "Interval fixture", totalMinutes: 120, startDate: now, deadline: now)
        state.courses = [course]
        let task = ScheduledTask(courseID: course.id, start: now.addingTimeInterval(-3600), durationMinutes: 60)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        return state
    }

    private func invert(_ task: inout ScheduledTask, kind: String = "both") {
        if kind != "endOnly" { task.floatingWindowStart = now.addingTimeInterval(kind == "startOnly" ? 60 : -1800) }
        if kind != "startOnly" { task.floatingWindowEnd = now.addingTimeInterval(kind == "endOnly" ? -3660 : -2400) }
    }

    func testLiveAndRecoveredInvertedWindowsRejectWithoutMutatingLedger() throws {
        for kind in ["both", "startOnly", "endOnly"] {
            for recovered in [false, true] {
                let state = try fixture()
                var ledger = SyncLedger()
                try ledger.capture(state)
                var task = state.tasks[0]
                invert(&task, kind: kind)
                if recovered { task.confirmedAt = nil; task.completedMinutes = 0; task.status = .planned }
                let key = "tasks/" + task.id.uuidString
                ledger.records[key]?.payload = try JSONEncoder().encode(task)
                ledger.records[key]?.deleted = recovered
                let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence
                XCTAssertThrowsError(try ledger.materialize(), "\(kind), recovered=\(recovered)")
                XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
                XCTAssertEqual(ledger.records, before)
                XCTAssertEqual(ledger.clock, clock)
                XCTAssertEqual(ledger.sequence, sequence)
            }
        }
    }

    func testCaptureAndBackupRejectInvertedWindowsBeforeMutation() throws {
        for kind in ["both", "startOnly", "endOnly"] {
            var state = try fixture(), ledger = SyncLedger()
            try ledger.capture(state)
            invert(&state.tasks[0], kind: kind)
            let before = ledger.records, clock = ledger.clock, sequence = ledger.sequence, input = state
            XCTAssertThrowsError(try ledger.capture(state))
            XCTAssertEqual(ledger.records, before)
            XCTAssertEqual(ledger.clock, clock)
            XCTAssertEqual(ledger.sequence, sequence)
            XCTAssertEqual(state, input)
            let data = try JSONEncoder().encode(PlannerBackup(state: state, reason: "Inverted interval"))
            let backup = try JSONDecoder().decode(PlannerBackup.self, from: data)
            XCTAssertThrowsError(try backup.validated())
        }
    }

    func testBackupChecksOriginalArchivedTasksEvenWhenCaptureDiscardsThem() throws {
        var state = try fixture(), ledger = SyncLedger()
        state.courses[0].isArchived = true
        invert(&state.tasks[0])
        try ledger.capture(state)
        XCTAssertTrue(try ledger.materialize().tasks.isEmpty)
        XCTAssertThrowsError(try PlannerBackup(state: state, reason: "Archived interval").validated())
    }

    func testNonfiniteEffectiveEndpointsAreInvalid() throws {
        let state = try fixture()
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            var task = state.tasks[0]
            task.floatingWindowStart = Date(timeIntervalSinceReferenceDate: value)
            XCTAssertFalse(task.hasValidPlanningInterval)
            task.floatingWindowStart = nil
            task.floatingWindowEnd = Date(timeIntervalSinceReferenceDate: value)
            XCTAssertFalse(task.hasValidPlanningInterval)
        }
    }

    func testLegacyPartialEqualAndEarlyConfirmedWindowsRemainReadable() throws {
        for kind in ["none", "startOnly", "endOnly", "both", "equal", "early"] {
            var state = try fixture()
            if ["startOnly", "both", "early"].contains(kind) { state.tasks[0].floatingWindowStart = now.addingTimeInterval(-5400) }
            if ["endOnly", "both", "early"].contains(kind) { state.tasks[0].floatingWindowEnd = now.addingTimeInterval(1800) }
            if kind == "equal" {
                state.tasks[0].floatingWindowStart = now.addingTimeInterval(-1800)
                state.tasks[0].floatingWindowEnd = now.addingTimeInterval(-1800)
            }
            if kind == "early" {
                state.tasks[0].confirmedAt = now.addingTimeInterval(-7200)
                state.completions[0].recordedAt = now.addingTimeInterval(-7200)
            }
            var ledger = SyncLedger()
            try ledger.capture(state)
            let restored = try ledger.materialize()
            XCTAssertEqual(restored.tasks, state.tasks, kind)
            XCTAssertEqual(restored.completedMinutes(for: restored.courses[0]), 20)
            _ = try CloudArchive(ledger: ledger).validated()
            _ = try PlannerBackup(state: state, reason: "Compatible interval").validated()
            _ = ScheduleEngine().assessSavedPlan(state: restored, now: now)
        }
    }

    func testUnrestoredHistoricalTombstoneWindowIsIgnored() throws {
        for referenced in [false, true] {
            let state = try fixture()
            var ledger = SyncLedger()
            try ledger.capture(state)
            var old = state.tasks[0]
            invert(&old)
            let key = "tasks/" + old.id.uuidString
            ledger.records[key]?.payload = try JSONEncoder().encode(old)
            ledger.records[key]?.deleted = true
            if !referenced { ledger.records["completions/" + state.completions[0].id.uuidString]?.deleted = true }
            let restored = try ledger.materialize()
            XCTAssertTrue(restored.tasks.isEmpty)
            XCTAssertEqual(restored.completions.count, referenced ? 1 : 0)
            _ = try CloudArchive(ledger: ledger).validated()
        }
    }

    func testMergedConfirmedTombstoneIsValidatedWhenRecovered() throws {
        for inverted in [false, true] {
            var state = try fixture()
            let original = state.tasks[0]
            let second = Course(name: "Second", totalMinutes: 60, startDate: now, deadline: now)
            state.courses.append(second)
            var ledger = SyncLedger()
            try ledger.capture(state)
            let merged = try state.mergeCourses(ids: [original.courseID, second.id], name: "Merged")
            try ledger.capture(state)
            var old = original
            if inverted { invert(&old) }
            else { old.floatingWindowStart = now.addingTimeInterval(-5400) }
            let key = "tasks/" + old.id.uuidString
            ledger.records[key]?.payload = try JSONEncoder().encode(old)
            ledger.records[key]?.deleted = true
            if inverted {
                XCTAssertThrowsError(try ledger.materialize())
                XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
            } else {
                let restored = try ledger.materialize()
                XCTAssertEqual(restored.tasks.first?.courseID, merged.id)
                XCTAssertEqual(restored.completedMinutes(for: merged), 20)
            }
        }
    }
}
