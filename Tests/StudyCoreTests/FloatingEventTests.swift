import XCTest
@testable import StudyCore

final class FloatingEventTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    func date(_ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: hour, minute: minute))!
    }
    func event(_ start: Int = 840, _ end: Int = 1080, _ duration: Int? = 60) -> FixedEvent {
        var e = FixedEvent(title: "浮动事务", startMinute: start, endMinute: end, startDate: date(), endDate: date())
        e.floatingDurationMinutes = duration
        return e
    }
    func state() -> PlannerState {
        var s = PlannerState()
        s.settings.availability = [.init(weekday: cal.component(.weekday, from: date()), startMinute: 840, endMinute: 1080)]
        s.courses = [.init(name: "数学", totalMinutes: 240, startDate: date(), deadline: date())]
        s.fixedEvents = [event()]
        return s
    }
    func testCapacityAndUncertainTaskWindows() {
        let s = state(), r = ScheduleEngine(calendar: cal).generate(state: s, now: date(13))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertEqual(r.risks.first?.availableMinutes, 180)
        XCTAssertEqual(r.risks.first?.unscheduledMinutes, 120)
        XCTAssertTrue(r.tasks.allSatisfy { $0.isFloating && $0.planningStart == date(14) && $0.planningEnd == date(18) })
    }
    func testOverlappingWindowsReserveBothDurations() throws {
        var s = state()
        let second = event(900, 1080, 90)
        try s.updateFixedEvent(second, now: date(13), calendar: cal)
        let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(13))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 60) // 90 free, 60-minute blocks
        XCTAssertEqual(r.risks.first?.availableMinutes, 90)
        XCTAssertThrowsError(try s.updateFixedEvent(event(840, 1080, 120), now: date(13), calendar: cal))
    }
    func testExactAppointmentsOnlyConflictWhenFloatingCannotFitContinuously() throws {
        var s = state()
        try s.updateFixedEvent(event(900, 960, nil), now: date(13), calendar: cal)
        XCTAssertEqual(s.fixedEvents.count, 2)
        XCTAssertThrowsError(try s.updateFixedEvent(event(840, 1080, 121), now: date(13), calendar: cal))
        let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(13))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
        XCTAssertTrue(r.tasks.allSatisfy { $0.end <= date(15) || $0.start >= date(16) })
    }
    func testWindowDoesNotConsumeOutsideAvailability() {
        var s = state()
        s.fixedEvents = [event(1080, 1200, 60)]
        let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(13))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 180)
        XCTAssertFalse(r.tasks.contains(where: \.isFloating))
    }
    func testFloatingEventUsesTimeBeforeOrAfterStudyAvailability() {
        for bounds in [(540, 660), (600, 720)] {
            var s = state()
            s.settings.availability = [.init(weekday: cal.component(.weekday, from: date()), startMinute: 600, endMinute: 660)]
            s.courses[0].totalMinutes = 60
            s.fixedEvents = [event(bounds.0, bounds.1, 60)]
            let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(8))
            XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
            XCTAssertEqual(r.tasks.first?.start, date(10))
            XCTAssertTrue(r.risks.isEmpty)
        }
    }
    func testFloatingPlacementOptimizesMultipleEventsTogether() {
        var s = state()
        s.settings.availability = [.init(weekday: cal.component(.weekday, from: date()), startMinute: 600, endMinute: 660)]
        s.courses[0].totalMinutes = 60
        // The first event's cheapest latest placement (11–12) blocks the second.
        // Jointly placing them at 9–10 and 11–13 preserves the whole study hour.
        s.fixedEvents = [event(540, 720, 60), event(540, 780, 120)]
        let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(8))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(r.risks.isEmpty)
    }
    func testOnlyUnavoidableStudyOverlapIsReserved() {
        var s = state()
        s.settings.availability = [.init(weekday: cal.component(.weekday, from: date()), startMinute: 600, endMinute: 660)]
        s.courses[0].totalMinutes = 60
        s.courses[0].minimumBlockMinutes = 30
        s.fixedEvents = [event(570, 660, 60)]
        let r = ScheduleEngine(calendar: cal).generate(state: s, now: date(8))
        XCTAssertEqual(r.tasks.reduce(0) { $0 + $1.durationMinutes }, 30)
        XCTAssertEqual(r.risks.first?.unscheduledMinutes, 30)
        s.fixedEvents = [event(540, 660, 60), event(540, 600, nil)]
        let blocked = ScheduleEngine(calendar: cal).generate(state: s, now: date(8))
        XCTAssertTrue(blocked.tasks.isEmpty, "A fixed appointment cannot be used as spare time")
        XCTAssertEqual(blocked.risks.first?.unscheduledMinutes, 60)
    }
    func testStartedWindowReplansFromNowWithoutDoubleBookingOrEarlyReview() {
        var s = state()
        s.settings.notificationMinute = 0
        _ = s.replan(now: date(13), calendar: cal)
        let original = s.tasks
        _ = s.replan(now: date(15, 30), calendar: cal)
        XCTAssertNotEqual(s.tasks, original)
        XCTAssertEqual(s.tasks.count, 1)
        XCTAssertEqual(s.tasks.first?.start, date(15, 30))
        XCTAssertTrue(s.confirmationCandidates(at: date(15, 30), calendar: cal).isEmpty)
        XCTAssertEqual(s.confirmationCandidates(at: date(18), calendar: cal).count, 1)
    }
    func testLegacyDecodeAndFloatingRoundTrip() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var s = state()
        _ = s.replan(now: date(13), calendar: cal)
        XCTAssertEqual(try decoder.decode(PlannerState.self, from: encoder.encode(s)), s)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(event())) as? [String: Any])
        data.removeValue(forKey: "floatingDurationMinutes")
        let legacy = try decoder.decode(FixedEvent.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertFalse(legacy.isFloating)
        XCTAssertEqual(legacy.occupiedMinutes, 240)
    }
    func testInvalidDurationAndFullWindowOccupation() throws {
        var s = state()
        for duration in [0, -1, 241] {
            XCTAssertThrowsError(try s.updateFixedEvent(event(840, 1080, duration), now: date(13), calendar: cal))
        }
        s.fixedEvents = [event(840, 1080, 240)]
        XCTAssertTrue(ScheduleEngine(calendar: cal).generate(state: s, now: date(13)).tasks.isEmpty)
    }
    func testSyncPreservesFloatingFields() throws {
        var s = state()
        _ = s.replan(now: date(13), calendar: cal)
        var ledger = SyncLedger()
        try ledger.capture(s)
        try JSONEncoder().encode(ledger).write(to: URL(fileURLWithPath: "/tmp/study-floating-swift-fixture.json"))
        let row = try XCTUnwrap(ledger.records["fixedEvents/" + s.fixedEvents[0].id.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(FixedEvent.self, from: row.payload).floatingDurationMinutes, 60)
        let task = try XCTUnwrap(s.tasks.first)
        let taskRow = try XCTUnwrap(ledger.records["tasks/" + task.id.uuidString])
        XCTAssertEqual(try JSONDecoder().decode(ScheduledTask.self, from: taskRow.payload).floatingWindowEnd, date(18))
    }
}
