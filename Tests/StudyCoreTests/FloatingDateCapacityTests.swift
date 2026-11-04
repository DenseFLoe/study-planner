import XCTest
@testable import StudyCore

final class FloatingDateCapacityTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ calendar: Calendar, month: Int = 3, day: Int = 8) -> Date {
        calendar.date(from: .init(year: 2026, month: month, day: day))!
    }
    private func fixture(day: Date, calendar: Calendar, window: (Int, Int) = (60, 240),
                         durations: [Int] = [90], availability: (Int, Int) = (60, 240)) -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map {
            .init(weekday: $0, startMinute: availability.0, endMinute: availability.1)
        }
        state.courses = [.init(name: "Synthetic DST course", totalMinutes: 60, startDate: day, deadline: day)]
        state.fixedEvents = durations.enumerated().map { index, duration in
            var event = FixedEvent(title: "Floating \(index)", startMinute: window.0, endMinute: window.1,
                                   startDate: day, endDate: day)
            event.id = stablePlannerID("date-floating-\(index)")
            event.floatingDurationMinutes = duration
            return event
        }
        return state
    }
    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        _ = try PlannerBackup(state: state, reason: "Synthetic floating dates").validated()
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        return try ledger.materialize()
    }
    private func floatingWarning(_ result: ScheduleResult) -> Bool {
        result.diagnostics.contains { $0.hasPrefix("浮动事项的连续时长") }
    }
    // A small independent oracle uses elapsed minutes, including when Foundation
    // resolves a nonexistent clock time outside the requested civil day.
    private func actualEventsFit(_ state: PlannerState, tasks: [ScheduledTask], day: Date, calendar: Calendar) -> Bool {
        let engine = ScheduleEngine(calendar: calendar)
        func offset(_ date: Date) -> Int { Int(date.timeIntervalSince(day) / 60) }
        let dayLength = offset(engine.instant(day: day, minute: 1440))
        var busy = [Bool](repeating: false, count: dayLength)
        let blocks = tasks.map { ($0.start, $0.end) } + state.fixedEvents.filter { !$0.isFloating }.map {
            (engine.instant(day: day, minute: $0.startMinute), engine.instant(day: day, minute: $0.endMinute))
        }
        for (start, end) in blocks {
            let lower = max(0, offset(start)), upper = min(dayLength, offset(end))
            if lower < upper { for minute in lower..<upper { busy[minute] = true } }
        }
        var jobs: [(start: Int, end: Int, minutes: Int)] = []
        for event in state.fixedEvents where event.isFloating {
            let first = offset(engine.instant(day: day, minute: event.startMinute))
            let last = offset(engine.instant(day: day, minute: event.endMinute))
            jobs.append((max(0, first), min(dayLength, last), event.occupiedMinutes))
        }
        jobs.sort { $0.end - $0.start - $0.minutes < $1.end - $1.start - $1.minutes }
        func visit(_ index: Int) -> Bool {
            if index == jobs.count { return true }
            let job = jobs[index], last = job.end - job.minutes
            guard job.start <= last else { return false }
            for start in job.start...last {
                let interval = start..<(start + job.minutes)
                if interval.contains(where: { busy[$0] }) { continue }
                for minute in interval { busy[minute] = true }
                if visit(index + 1) { return true }
                for minute in interval { busy[minute] = false }
            }
            return false
        }
        return visit(0)
    }

    func testPartialGapCannotCreditShortenedFloatingWitnessAsFullDuration() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        var input = fixture(day: day, calendar: cal)
        let event = input.fixedEvents.removeFirst()
        try input.updateFixedEvent(event, now: day, calendar: cal)
        let state = try roundTrip(input), before = state
        XCTAssertEqual(engine.instant(day: day, minute: 240).timeIntervalSince(engine.instant(day: day, minute: 60)), 120 * 60)
        let result = engine.generate(state: state, now: day)
        XCTAssertTrue(result.tasks.isEmpty, "The 120-minute window cannot contain both a 90-minute event and a 60-minute lesson")
        XCTAssertEqual(result.risks.first?.unscheduledMinutes, 60)
        XCTAssertEqual(result.risks.first?.availableMinutes, 30)
        XCTAssertFalse(floatingWarning(result), "The event itself fits; only the course lacks capacity")
        XCTAssertEqual(state, before)
    }

    func testActualFallbackPreservesFeasiblePartialGapWithoutFalseWarning() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        let state = try roundTrip(fixture(day: day, calendar: cal, availability: (60, 300))), before = state
        let result = engine.generate(state: state, now: day)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertTrue(result.tasks.allSatisfy { $0.start >= engine.instant(day: day, minute: 60) && $0.end <= engine.instant(day: day, minute: 300) })
        XCTAssertEqual(state, before)
    }

    func testEntirelySkippedWindowWarnsEvenWithNoMissingCourseWork() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        for hasCourse in [false, true] {
            var input = fixture(day: day, calendar: cal, window: (120, 180), durations: [60], availability: (240, 300))
            if !hasCourse { input.courses = [] }
            let state = try roundTrip(input), before = state
            let result = engine.generate(state: state, now: day)
            XCTAssertTrue(floatingWarning(result))
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, hasCourse ? 60 : 0)
            XCTAssertTrue(result.risks.isEmpty)
            XCTAssertEqual(state, before)
        }
    }

    func testExactGapCannotBeUsedToJoinDiscontinuousFloatingCapacity() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        var input = fixture(day: day, calendar: cal, availability: (240, 300))
        input.fixedEvents.append(.init(title: "Exact break in event window", startMinute: 180, endMinute: 210,
                                       startDate: day, endDate: day))
        let state = try roundTrip(input), before = state
        let result = engine.generate(state: state, now: day)
        XCTAssertTrue(floatingWarning(result), "The remaining pieces are 60 and 30 minutes, not one continuous 90-minute slot")
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(state, before)
    }

    func testMultipleFloatingEventsRequireACompleteActualWitness() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        for durations in [[60, 60], [60, 61]] {
            let state = try roundTrip(fixture(day: day, calendar: cal, durations: durations, availability: (60, 300))), before = state
            let result = engine.generate(state: state, now: day)
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
            XCTAssertEqual(result.tasks.first?.start, engine.instant(day: day, minute: 240))
            XCTAssertEqual(floatingWarning(result), durations == [60, 61])
            XCTAssertEqual(state, before)
        }
    }

    func testOrdinaryAndRepeatedHourKeepExistingConservativeReservation() throws {
        for (zone, month, number, window, duration, availability, expectedStart) in [
            ("America/New_York", 3, 9, (60, 240), 90, (60, 240), 60),
            ("UTC", 3, 8, (60, 240), 90, (60, 240), 60),
            ("America/New_York", 11, 1, (0, 120), 120, (0, 180), 120)
        ] {
            let cal = calendar(zone), day = date(cal, month: month, day: number), engine = ScheduleEngine(calendar: cal)
            let state = try roundTrip(fixture(day: day, calendar: cal, window: window, durations: [duration], availability: availability)), before = state
            let result = engine.generate(state: state, now: day)
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
            XCTAssertEqual(result.tasks.first?.start, engine.instant(day: day, minute: expectedStart))
            XCTAssertTrue(result.diagnostics.isEmpty)
            XCTAssertTrue(result.risks.isEmpty)
            XCTAssertEqual(state, before)
        }
    }

    func testRecurringOccurrenceUsesItsDateAndHonorsExcludedGapDay() throws {
        let cal = calendar(), first = date(cal, day: 7), gap = date(cal), last = date(cal, day: 9)
        let engine = ScheduleEngine(calendar: cal)
        for excluded in [false, true] {
            var input = fixture(day: first, calendar: cal, window: (120, 180), durations: [60], availability: (240, 300))
            input.courses[0].deadline = last
            input.fixedEvents[0].endDate = last
            input.fixedEvents[0].weekdays = Set(1...7)
            if excluded { input.fixedEvents[0].excludedDates = [gap] }
            let state = try roundTrip(input), before = state
            let result = engine.generate(state: state, now: first)
            XCTAssertEqual(result.diagnostics.filter { $0.hasPrefix("浮动事项的连续时长") }.count, excluded ? 0 : 1)
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
            XCTAssertEqual(state, before)
        }
    }

    func testOrdinaryDateMatchesAndroidElapsedMinuteControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/floating-date-capacity.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate floating date controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let state = try JSONDecoder().decode(PlannerState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"])))
            let expected = try JSONDecoder().decode([ScheduledTask].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["tasks"])))
            let now = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(row["now"] as? Double))
            let before = state, result = ScheduleEngine(calendar: calendar("Asia/Shanghai")).generate(state: state, now: now)
            XCTAssertEqual(result.tasks, expected)
            XCTAssertTrue(result.diagnostics.isEmpty)
            XCTAssertTrue(result.risks.isEmpty)
            XCTAssertEqual(state, before)
        }
    }

    func testHalfHourGapWitnessRespectsActualEventWindows() throws {
        let cal = calendar("Australia/Lord_Howe"), day = date(cal, month: 10, day: 4)
        var input = fixture(day: day, calendar: cal, window: (120, 270), durations: [45], availability: (60, 270))
        var second = FixedEvent(title: "Second floating event", startMinute: 60, endMinute: 210, startDate: day, endDate: day)
        second.floatingDurationMinutes = 60
        input.fixedEvents.append(second)
        input.courses[0].totalMinutes = 15
        input.courses[0].minimumBlockMinutes = 15
        let state = try roundTrip(input), before = state
        let result = ScheduleEngine(calendar: cal).generate(state: state, now: ScheduleEngine(calendar: cal).instant(day: day, minute: 60))
        // Do not hard-code how Linux or Darwin resolves the missing 02:00.
        let eventsFit = actualEventsFit(state, tasks: [], day: day, calendar: cal)
        XCTAssertEqual(floatingWarning(result), !eventsFit)
        if !floatingWarning(result) {
            XCTAssertTrue(actualEventsFit(state, tasks: result.tasks, day: day, calendar: cal))
        }
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 15)
        XCTAssertEqual(state, before)
    }

    func testHalfHourGapDoesNotReserveBeyondTheCivilDayForAFeasibleEvent() throws {
        let cal = calendar("Australia/Lord_Howe"), day = date(cal, month: 10, day: 4)
        var input = fixture(day: day, calendar: cal, window: (60, 120), durations: [30], availability: (60, 270))
        input.courses[0].totalMinutes = 15
        input.courses[0].minimumBlockMinutes = 15
        let state = try roundTrip(input), before = state
        let result = ScheduleEngine(calendar: cal).generate(state: state, now: day)
        XCTAssertTrue(actualEventsFit(state, tasks: [], day: day, calendar: cal))
        XCTAssertFalse(floatingWarning(result))
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 15)
        XCTAssertTrue(actualEventsFit(state, tasks: result.tasks, day: day, calendar: cal))
        XCTAssertEqual(state, before)
    }
}
