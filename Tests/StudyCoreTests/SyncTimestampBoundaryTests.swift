import XCTest
@testable import StudyCore

final class SyncTimestampBoundaryTests: XCTestCase {
    private func fixture(timestamp: Double) -> PlannerState {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var state = PlannerState()
        let course = Course(name: "Timestamp boundary", totalMinutes: 120, startDate: now, deadline: now)
        state.courses = [course]
        state.tasks = (0..<2).map { index in
            var task = ScheduledTask(courseID: course.id, start: Date(timeIntervalSinceReferenceDate: timestamp), durationMinutes: 60)
            task.id = stablePlannerID("timestamp-boundary-\(index)")
            return task
        }
        return state
    }

    func testFiniteOutOfRangeSlotTimestampsRejectWithoutTrapping() throws {
        for timestamp in [1e20, -1e20, Double(Int64.max), Double(Int64.min).nextDown] {
            let state = fixture(timestamp: timestamp)
            var ledger = SyncLedger()
            try ledger.capture(state)
            let before = ledger.records
            XCTAssertThrowsError(try ledger.materialize())
            XCTAssertThrowsError(try CloudArchive(ledger: ledger).validated())
            XCTAssertEqual(ledger.records, before)
            let data = try JSONEncoder().encode(PlannerBackup(state: state, reason: "Synthetic boundary"))
            let backup = try JSONDecoder().decode(PlannerBackup.self, from: data)
            XCTAssertThrowsError(try backup.validated())
        }
    }

    func testFractionalAndRepresentableBoundarySlotTimestampsRemainReadable() throws {
        for timestamp in [800_000_000.75, -800_000_000.75, Double(Int64.max).nextDown, Double(Int64.min)] {
            var ledger = SyncLedger()
            try ledger.capture(fixture(timestamp: timestamp))
            let state = try ledger.materialize()
            XCTAssertEqual(state.tasks.count, 1)
            XCTAssertEqual(state.tasks.first?.start.timeIntervalSinceReferenceDate, timestamp)
            XCTAssertEqual(state.tasks.first?.durationMinutes, 60)
        }
    }
}
