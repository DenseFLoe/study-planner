import XCTest
@testable import StudyCore

final class FixedEventDateCapacityTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func day(_ cal: Calendar, month: Int = 3, date: Int = 8) -> Date {
        cal.date(from: .init(year: 2026, month: month, day: date))!
    }
    private func event(_ start: Int, _ end: Int, _ duration: Int?, day: Date) -> FixedEvent {
        var value = FixedEvent(title: "Synthetic event capacity", startMinute: start, endMinute: end, startDate: day, endDate: day)
        value.floatingDurationMinutes = duration
        return value
    }
    private func assertCapacityConflict(_ body: () throws -> Void, id: UUID, date: Date,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case PlannerError.fixedConflict(let conflicts) = error else {
                return XCTFail("Expected the existing fixed-conflict error", file: file, line: line)
            }
            XCTAssertEqual(conflicts.map(\.eventID), [id], file: file, line: line)
            XCTAssertEqual(conflicts.map(\.date), [date], file: file, line: line)
            XCTAssertEqual(conflicts.map(\.reason), [.floatingCapacity], file: file, line: line)
        }
    }

    func testSingleFloatingOccurrenceRequiresItsDeclaredActualDuration() {
        let cal = calendar(), date = day(cal)
        for requested in [event(60, 180, 90, day: date), event(120, 180, 60, day: date)] {
            var state = PlannerState()
            let before = state
            XCTAssertThrowsError(try state.updateFixedEvent(requested, now: date, calendar: cal)) {
                guard case PlannerError.invalidFixedEvent = $0 else { return XCTFail("Expected single-event validation error") }
            }
            XCTAssertEqual(state, before)
        }
    }

    func testCombinedActualCapacityRejectsTheNewEventAtomically() throws {
        let cal = calendar(), date = day(cal)
        var state = PlannerState()
        let old = event(60, 240, 90, day: date), requested = event(60, 240, 60, day: date)
        try state.updateFixedEvent(old, now: date, calendar: cal)
        let before = state
        assertCapacityConflict({ try state.updateFixedEvent(requested, now: date, calendar: cal) }, id: old.id, date: date)
        XCTAssertEqual(state, before)
    }

    func testExactAppointmentFragmentsCannotSupplyOneContinuousFloatingSpan() throws {
        let cal = calendar(), date = day(cal)
        var state = PlannerState()
        let exact = event(180, 210, nil, day: date), requested = event(60, 240, 90, day: date)
        try state.updateFixedEvent(exact, now: date, calendar: cal)
        let before = state
        assertCapacityConflict({ try state.updateFixedEvent(requested, now: date, calendar: cal) }, id: exact.id, date: date)
        XCTAssertEqual(state, before)
    }

    func testRestoreUsesActualCapacityAndPreservesExclusionWhenRejected() throws {
        let cal = calendar(), date = day(cal)
        var state = PlannerState(), skipped = event(60, 240, 90, day: date)
        skipped.excludedDates = [date]
        state.fixedEvents = [skipped]
        let other = event(60, 240, 60, day: date)
        try state.updateFixedEvent(other, now: date, calendar: cal)
        let before = state
        assertCapacityConflict({ try state.setFixedEventSkipped(id: skipped.id, on: date, skipped: false, now: date, calendar: cal) }, id: other.id, date: date)
        XCTAssertEqual(state, before)
        state.removeFixedEvent(id: other.id)
        try state.setFixedEventSkipped(id: skipped.id, on: date, skipped: false, now: date, calendar: cal)
        var restored = skipped
        restored.excludedDates = []
        XCTAssertEqual(state.fixedEvents, [restored])
    }

    func testFeasiblePartialGapDoesNotGetRejectedAndKeepsStoredFields() throws {
        let cal = calendar(), date = day(cal)
        var state = PlannerState()
        let requested = event(60, 240, 90, day: date)
        try state.updateFixedEvent(requested, now: date, calendar: cal)
        XCTAssertEqual(state.fixedEvents, [requested])
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        XCTAssertEqual(try ledger.materialize(), state)
    }

    func testRecurringSingleRuleCanExplicitlySkipOnlyTheInvalidGapDate() throws {
        let cal = calendar(), first = day(cal, date: 7), gap = day(cal), last = day(cal, date: 9)
        var requested = event(60, 180, 90, day: first)
        requested.endDate = last
        requested.weekdays = Set(1...7)
        var state = PlannerState()
        let before = state
        XCTAssertThrowsError(try state.updateFixedEvent(requested, now: first, calendar: cal))
        XCTAssertEqual(state, before)
        try state.updateFixedEvent(requested, now: first, calendar: cal, skippingDates: [gap])
        var expected = requested
        expected.excludedDates = [gap]
        XCTAssertEqual(state.fixedEvents, [expected])
        XCTAssertTrue(expected.occurs(on: first, calendar: cal))
        XCTAssertFalse(expected.occurs(on: gap, calendar: cal))
        XCTAssertTrue(expected.occurs(on: last, calendar: cal))
    }

    func testSkipExistingResolvesOnlyTheActualConflictAndIncomingSkipWins() throws {
        let cal = calendar(), first = day(cal, date: 7), gap = day(cal), last = day(cal, date: 9)
        var old = event(60, 240, 90, day: first), requested = event(60, 240, 60, day: first)
        old.endDate = last; old.weekdays = Set(1...7)
        requested.endDate = last; requested.weekdays = Set(1...7)
        for skipIncoming in [false, true] {
            var state = PlannerState()
            state.fixedEvents = [old]
            try state.updateFixedEvent(requested, now: first, calendar: cal,
                                       skippingDates: skipIncoming ? [gap] : [], skippingExistingDates: [gap])
            let savedOld = try XCTUnwrap(state.fixedEvents.first { $0.id == old.id })
            let savedNew = try XCTUnwrap(state.fixedEvents.first { $0.id == requested.id })
            XCTAssertEqual(savedOld.excludedDates, skipIncoming ? [] : [gap])
            XCTAssertEqual(savedNew.excludedDates, skipIncoming ? [gap] : [])
            XCTAssertEqual(savedOld.id, old.id)
            XCTAssertEqual(savedOld.startDate, first)
            XCTAssertEqual(savedOld.endDate, last)
            XCTAssertTrue(savedOld.occurs(on: first, calendar: cal))
            XCTAssertTrue(savedOld.occurs(on: last, calendar: cal))
        }
    }

    func testUnhandledDatesDoNotPartiallySkipExistingOccurrences() throws {
        let cal = calendar(), first = day(cal, date: 7), last = day(cal, date: 9)
        var old = event(60, 240, 90, day: first), requested = event(60, 240, 100, day: first)
        old.endDate = last; old.weekdays = Set(1...7)
        requested.endDate = last; requested.weekdays = Set(1...7)
        var state = PlannerState()
        state.fixedEvents = [old]
        let before = state
        XCTAssertThrowsError(try state.updateFixedEvent(requested, now: first, calendar: cal, skippingExistingDates: [first]))
        XCTAssertEqual(state, before)
    }

    func testUnrelatedExistingConflictDoesNotBlockThisComponent() throws {
        let cal = calendar(), date = day(cal)
        var state = PlannerState()
        state.fixedEvents = [event(0, 30, nil, day: date), event(15, 45, nil, day: date)]
        let before = state.fixedEvents, requested = event(60, 240, 90, day: date)
        try state.updateFixedEvent(requested, now: date, calendar: cal)
        XCTAssertEqual(state.fixedEvents, before + [requested])
    }

    func testOrdinaryAndRepeatedHourCapacityUsesActualCompleteWitness() throws {
        for (zone, month, number, end, durations) in [
            ("UTC", 3, 8, 240, [90, 60]), ("Asia/Shanghai", 3, 8, 240, [90, 60]),
            ("America/New_York", 3, 9, 240, [90, 60]), ("America/New_York", 11, 1, 120, [60, 60])
        ] {
            let cal = calendar(zone), date = day(cal, month: month, date: number)
            var state = PlannerState()
            let events = durations.map { event(60, end, $0, day: date) }
            for requested in events { XCTAssertNoThrow(try state.updateFixedEvent(requested, now: date, calendar: cal)) }
            XCTAssertEqual(state.fixedEvents, events)
        }
    }

    func testStartedOccurrenceKeepsItsPastRuleWhileValidatingOnlyFutureEdits() throws {
        let cal = calendar(), first = day(cal, date: 7), today = day(cal), last = day(cal, date: 9)
        let engine = ScheduleEngine(calendar: cal)
        var old = event(60, 180, 30, day: first)
        old.endDate = last; old.weekdays = Set(1...7)
        var state = PlannerState()
        state.fixedEvents = [old]
        var requested = old
        requested.floatingDurationMinutes = 100
        try state.updateFixedEvent(requested, now: engine.instant(day: today, minute: 90), calendar: cal)
        let kept = try XCTUnwrap(state.fixedEvents.first { $0.id == old.id })
        let future = try XCTUnwrap(state.fixedEvents.first { $0.id != old.id })
        XCTAssertEqual(kept.endDate, today)
        XCTAssertEqual(kept.floatingDurationMinutes, 30)
        XCTAssertEqual(future.startDate, last)
        XCTAssertEqual(future.floatingDurationMinutes, 100)
    }

    func testOrdinaryDateMatchesAndroidEditRestoreAndSkipControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/fixed-event-date-capacity.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate fixed-event date controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 7)
        let cal = calendar("Asia/Shanghai")
        for row in rows {
            var state = try JSONDecoder().decode(PlannerState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"])))
            let requested = try JSONDecoder().decode(FixedEvent.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["event"])))
            let expectedEvents = try JSONDecoder().decode([FixedEvent].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["events"])))
            let now = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(row["now"] as? Double))
            let date = cal.startOfDay(for: now), operation = try XCTUnwrap(row["operation"] as? String)
            let before = state
            func apply() throws {
                if operation == "restore" { try state.setFixedEventSkipped(id: requested.id, on: date, skipped: false, now: now, calendar: cal) }
                else { try state.updateFixedEvent(requested, now: now, calendar: cal,
                    skippingDates: operation == "skipIncoming" ? [date] : [], skippingExistingDates: operation == "skipExisting" ? [date] : []) }
            }
            if try XCTUnwrap(row["succeeds"] as? Bool) {
                try apply()
                var expected = before
                expected.fixedEvents = expectedEvents
                XCTAssertEqual(state, expected)
            } else {
                XCTAssertThrowsError(try apply()) { error in
                    guard case PlannerError.fixedConflict(let conflicts) = error else { return XCTFail("Expected capacity conflict") }
                    XCTAssertTrue(conflicts.allSatisfy { $0.reason == .floatingCapacity })
                }
                XCTAssertEqual(state, before)
            }
        }
    }
}
