import XCTest
@testable import StudyCore

extension ScheduleEngineTests {
    private func recurringEvent() -> FixedEvent {
        .init(title: "学校", startMinute: 480, endMinute: 600,
              startDate: date(13), endDate: date(17), weekdays: Set(1...7))
    }

    func testSkipStartedOccurrenceTodayKeepsOtherDaysAndRuleIdentity() throws {
        var s = state(hours: 1, deadline: 15)
        let event = recurringEvent()
        s.fixedEvents = [event]
        try s.setFixedEventSkipped(id: event.id, on: date(14, 23), skipped: true, now: date(14, 8, 30), calendar: cal)
        var expected = event
        expected.excludedDates = [date(14)]
        XCTAssertEqual(s.fixedEvents, [expected])
        XCTAssertTrue(expected.occurs(on: date(13), calendar: cal))
        XCTAssertFalse(expected.occurs(on: date(14), calendar: cal))
        XCTAssertTrue(expected.occurs(on: date(15), calendar: cal))
        let r = s.replan(now: date(14, 8, 30), calendar: cal)
        XCTAssertEqual(r.tasks.first?.start, date(14, 8, 30))
        assertValid(r, s, now: date(14, 8, 30))
    }

    func testRemovingFutureOccurrenceReplacesFutureTasksAndPreservesProgress() throws {
        var s = state(hours: 3, deadline: 15)
        s.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let event = recurringEvent()
        s.fixedEvents = [event]
        let history = ScheduledTask(courseID: s.courses[0].id, start: date(13, 8), durationMinutes: 60)
        let done = ScheduledTask(courseID: s.courses[0].id, start: date(14, 6), durationMinutes: 60)
        s.tasks = [history, done]
        try s.confirm(taskID: done.id, actualMinutes: 60, now: date(14, 7))
        let confirmed = try XCTUnwrap(s.tasks.first { $0.id == done.id })
        let records = s.completions
        XCTAssertTrue(s.replan(now: date(14, 7), calendar: cal).tasks.isEmpty)
        try s.setFixedEventSkipped(id: event.id, on: date(15), skipped: true, now: date(14, 7), calendar: cal)
        let r = s.replan(now: date(14, 7), calendar: cal)
        XCTAssertFalse(r.tasks.isEmpty)
        XCTAssertTrue(r.tasks.allSatisfy { cal.isDate($0.start, inSameDayAs: date(15)) })
        XCTAssertTrue(s.tasks.contains(history))
        XCTAssertTrue(s.tasks.contains(confirmed))
        XCTAssertEqual(s.completions, records)
        XCTAssertTrue(s.fixedEvents[0].occurs(on: date(14), calendar: cal))
        assertValid(r, s, now: date(14, 7))
    }

    func testSkipTodayMovesLearningFromFutureBackToReleasedWindow() throws {
        var s = state(hours: 1, deadline: 15)
        s.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let event = FixedEvent(title: "会议", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(14))
        s.fixedEvents = [event]
        let before = s.replan(now: date(14, 7), calendar: cal)
        XCTAssertEqual(before.tasks.first?.start, date(15, 8))
        try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: true, now: date(14, 7), calendar: cal)
        let after = s.replan(now: date(14, 7), calendar: cal)
        XCTAssertEqual(after.tasks.first?.start, date(14, 8))
        XCTAssertEqual(minutes(after.tasks), 60)
        XCTAssertEqual(s.tasks, after.tasks)
        try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: false, now: date(14, 7), calendar: cal)
        XCTAssertEqual(s.fixedEvents, [event])
        XCTAssertEqual(s.replan(now: date(14, 7), calendar: cal).tasks, before.tasks)
    }

    func testSkippedFloatingWindowReleasesCapacityAndUncertainty() throws {
        var s = state(hours: 2, deadline: 14, unit: 120)
        s.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 600)]
        var event = recurringEvent()
        event.floatingDurationMinutes = 60
        s.fixedEvents = [event]
        XCTAssertTrue(s.replan(now: date(14, 7), calendar: cal).tasks.isEmpty)
        try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: true, now: date(14, 7), calendar: cal)
        let r = s.replan(now: date(14, 7), calendar: cal)
        XCTAssertEqual(minutes(r.tasks), 120)
        XCTAssertTrue(r.risks.isEmpty)
        XCTAssertTrue(r.tasks.allSatisfy { !$0.isFloating })
        XCTAssertTrue(s.fixedEvents[0].occurs(on: date(15), calendar: cal))
    }

    func testInvalidSkipDatesAndIDsAreAtomicAndRepeatedSkipIsIdempotent() throws {
        var s = PlannerState()
        var event = recurringEvent()
        event.weekdays = [2]
        s.fixedEvents = [event]
        let original = s
        for (id, day) in [(event.id, date(13)), (event.id, date(15)), (event.id, date(18)), (UUID(), date(14))] {
            XCTAssertThrowsError(try s.setFixedEventSkipped(id: id, on: day, skipped: true, now: date(14, 7), calendar: cal))
            XCTAssertEqual(s, original)
        }
        try s.setFixedEventSkipped(id: event.id, on: date(14, 12), skipped: true, now: date(14, 7), calendar: cal)
        let skipped = s
        try s.setFixedEventSkipped(id: event.id, on: date(14, 23), skipped: true, now: date(14, 7), calendar: cal)
        XCTAssertEqual(s, skipped)
        XCTAssertThrowsError(try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: false, now: date(15, 7), calendar: cal))
        XCTAssertEqual(s, skipped)
    }

    func testRestorationChecksOnlySelectedDateAndRejectsConflictsAtomically() throws {
        for floating in [false, true] {
            var s = PlannerState()
            var event = recurringEvent()
            if floating { event.floatingDurationMinutes = 90 }
            s.fixedEvents = [event]
            try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: true, now: date(14, 8, 30), calendar: cal)
            var other = event
            other.id = UUID()
            other.startDate = date(14)
            other.endDate = date(14)
            try s.updateFixedEvent(other, now: date(14, 8, 30), calendar: cal)
            let before = s
            XCTAssertThrowsError(try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: false, now: date(14, 8, 30), calendar: cal)) { error in
                guard case PlannerError.fixedConflict(let conflicts) = error else { return XCTFail("Expected fixed conflict") }
                XCTAssertEqual(conflicts.first?.date, self.date(14))
            }
            XCTAssertEqual(s, before)
            s.fixedEvents.removeAll { $0.id == other.id }
            // An unrelated conflict on tomorrow must not block today's restoration.
            other.startDate = date(15)
            other.endDate = date(15)
            s.fixedEvents.append(other)
            try s.setFixedEventSkipped(id: event.id, on: date(14), skipped: false, now: date(14, 8, 30), calendar: cal)
            XCTAssertEqual(s.fixedEvents.first, event)
        }
    }

    func testNonMidnightExclusionsRestoreAndSurviveSync() throws {
        var s = PlannerState()
        var event = recurringEvent()
        event.excludedDates = [date(14, 12), date(16, 23)]
        s.fixedEvents = [event]
        try s.setFixedEventSkipped(id: event.id, on: date(14, 9), skipped: false, now: date(14, 8, 30), calendar: cal)
        XCTAssertEqual(s.fixedEvents[0].excludedDates, [date(16)])
        var a = SyncLedger(), b = SyncLedger()
        try a.capture(s)
        try b.merge(a.changes(after: 0))
        var peer = try b.materialize()
        XCTAssertEqual(peer.fixedEvents, s.fixedEvents)
        try peer.setFixedEventSkipped(id: event.id, on: date(14), skipped: true, now: date(14, 8, 30), calendar: cal)
        try b.capture(peer)
        try a.merge(b.changes(after: 0))
        XCTAssertEqual(try a.materialize().fixedEvents[0].excludedDates, [date(14), date(16)])
        XCTAssertEqual(try a.materialize().fixedEvents[0].id, event.id)
    }
}
