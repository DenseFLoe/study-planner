import XCTest
import StudyCore
@testable import StudyPlanner

final class AssistantTimeCheckTests: XCTestCase {
    private let basis = AssistantSimulation.snapshot()
    private var day: Date { basis.calendar.startOfDay(for: basis.now) }
    private func task(_ start: Int, _ end: Int, status: TaskStatus = .planned) -> ScheduledTask {
        ScheduledTask(courseID: AssistantSimulation.courseID, start: day.addingTimeInterval(Double(start * 60)), durationMinutes: end - start, status: status)
    }
    private func event(_ start: Int, _ end: Int, floating: Int? = nil) -> FixedEvent {
        var value = FixedEvent(title: "private-event-title", startMinute: start, endMinute: end, startDate: day, endDate: day)
        value.floatingDurationMinutes = floating; return value
    }
    private func check(_ tasks: [ScheduledTask], _ events: [FixedEvent] = [], offset: Int = 0) throws -> [String: Any] {
        var state = basis.state; state.tasks = tasks; state.fixedEvents = events
        let snapshot = AssistantSnapshot(state: state, now: basis.now, calendar: basis.calendar)
        let before = try assistantJSON(state)
        let result = try AssistantTimeCheck.inspect(snapshot: snapshot, day: day, offset: offset)
        XCTAssertEqual(try assistantJSON(snapshot.state), before)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self).contains("private-event-title"))
        return result
    }
    func testDisjointAndTouchingFixedIntervalsAreNotConflicts() throws {
        let result = try check([task(480, 540), task(540, 600), task(720, 780)], [event(660, 720)])
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 0)
        XCTAssertEqual(result["fixed_check_complete"] as? Bool, true)
        XCTAssertEqual((result["rows"] as? [[String: Any]])?.count, 0)
    }
    func testAllNestedOverlapsAndTaskEventEventPairsAreReported() throws {
        let result = try check([task(480, 720), task(540, 600), task(660, 690)], [event(570, 630), event(615, 645)])
        // Long task overlaps every other item (4), short task/event (1), event/event (1).
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 6)
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.compactMap { $0["overlap_minutes"] as? Double }.sorted(), [15, 30, 30, 30, 60, 60])
        XCTAssertTrue(rows.allSatisfy { $0["kind"] as? String == "fixed_overlap" })
    }
    func testConfirmedAndHistoricalTasksDoNotReserveTheirOldPlans() throws {
        var completed = task(480, 720, status: .completed)
        completed.confirmedAt = day.addingTimeInterval(500 * 60); completed.completedMinutes = 20
        var confirmedPlanned = task(480, 720); confirmedPlanned.confirmedAt = basis.now
        let result = try check([task(540, 600), completed, confirmedPlanned, task(480, 720, status: .partial),
                                task(480, 720, status: .missed), task(480, 720, status: .rescheduled)])
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 0)
        XCTAssertEqual(result["fixed_interval_count"] as? Int, 1)
        XCTAssertEqual(result["excluded_confirmed_task_count"] as? Int, 5)
    }
    func testFloatingWindowsAreNotFixedOverlapsAndContinuityIsChecked() throws {
        var moving = task(480, 540)
        moving.floatingWindowStart = day.addingTimeInterval(480 * 60)
        moving.floatingWindowEnd = day.addingTimeInterval(720 * 60)
        let result = try check([task(540, 600), moving], [event(480, 720, floating: 180)])
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 0)
        XCTAssertEqual(result["floating_window_count"] as? Int, 2)
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        let singles = rows.filter { $0["kind"] as? String == "floating_window" }
        XCTAssertEqual(Set(singles.compactMap { $0["result"] as? String }), ["individually_fits", "proven_continuous_deficit"])
        XCTAssertTrue(singles.allSatisfy { $0["longest_free_minutes"] as? Double == 120 })
        XCTAssertTrue(singles.allSatisfy { $0["available_minutes"] as? Double == 180 })
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "floating_total_deficit" }.first?["deficit_minutes"] as? Double, 60)
    }
    func testPassingIndividualBoundsDoesNotClaimJointFeasibility() throws {
        let result = try check([], [event(480, 600, floating: 30), event(480, 600, floating: 30)])
        XCTAssertEqual(result["proven_floating_deficit_count"] as? Int, 0)
        XCTAssertEqual(result["joint_floating_status"] as? String, "not_verified")
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 0)
    }
    func testCrossDayFixedOverlapIsClippedAndFloatingWindowStaysUnknown() throws {
        var moving = task(-60, 0)
        moving.floatingWindowStart = day.addingTimeInterval(-3600)
        moving.floatingWindowEnd = day.addingTimeInterval(7200)
        let result = try check([task(-60, 30), task(0, 60), moving])
        XCTAssertEqual(result["fixed_overlap_count"] as? Int, 1)
        let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["overlap_minutes"] as? Double, 30)
        XCTAssertEqual(rows.last?["result"] as? String, "outside_day_not_checked")
    }
    func testPaginationIncludesAllOverlapPairsAndDoesNotHideTotals() throws {
        let tasks = (0..<8).map { _ in task(480, 540) }
        let first = try check(tasks), second = try check(tasks, offset: 20)
        XCTAssertEqual(first["fixed_overlap_count"] as? Int, 28)
        XCTAssertEqual(first["total"] as? Int, 28)
        XCTAssertEqual(first["next_offset"] as? String, "20")
        XCTAssertEqual((first["rows"] as? [[String: Any]])?.count, 20)
        XCTAssertEqual((second["rows"] as? [[String: Any]])?.count, 8)
        XCTAssertTrue(second["next_offset"] is NSNull)
        XCTAssertThrowsError(try check(tasks, offset: 29))
    }
    func testInvalidEventsAreReportedAsIncompleteInsteadOfConflictFree() throws {
        let result = try check([], [event(700, 600)])
        XCTAssertEqual(result["invalid_entry_count"] as? Int, 1)
        XCTAssertEqual(result["fixed_check_complete"] as? Bool, false)
    }
}
