import XCTest
@testable import StudyCore

final class DailyFloatingDateTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func date(_ cal: Calendar, month: Int = 3, day: Int = 8) -> Date {
        cal.date(from: .init(year: 2026, month: month, day: day))!
    }
    private func fixture(day: Date, calendar: Calendar, end: Int = 240, durations: [Int] = [90]) -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "Synthetic daily floating dates", totalMinutes: 40, startDate: day, deadline: day)
        state.courses = [course]
        state.settings.availability = [.init(weekday: calendar.component(.weekday, from: day), startMinute: 60, endMinute: end)]
        let engine = ScheduleEngine(calendar: calendar)
        state.tasks = [60, 95].enumerated().map {
            .init(courseID: course.id, start: engine.instant(day: day, minute: $0.element), durationMinutes: 20, lessonID: "lesson-\($0.offset)")
        }
        state.fixedEvents = durations.enumerated().map { index, duration in
            var event = FixedEvent(title: "Floating \(index)", startMinute: 60, endMinute: 240, startDate: day, endDate: day)
            event.id = stablePlannerID("daily-floating-date-\(index)")
            event.floatingDurationMinutes = duration
            return event
        }
        return state
    }
    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        _ = try PlannerBackup(state: state, reason: "Synthetic floating swap").validated()
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        return try ledger.materialize()
    }
    private func eventsFit(_ state: PlannerState, tasks: [ScheduledTask], day: Date, calendar: Calendar) -> Bool {
        let engine = ScheduleEngine(calendar: calendar)
        func offset(_ date: Date) -> Int { Int(date.timeIntervalSince(day) / 60) }
        let dayLength = offset(engine.instant(day: day, minute: 1440))
        var busy = [Bool](repeating: false, count: dayLength)
        let blocks = tasks.map { ($0.start, $0.end) } + state.fixedEvents.filter { !$0.isFloating }.map {
            (engine.instant(day: day, minute: $0.startMinute), engine.instant(day: day, minute: $0.endMinute))
        }
        for (start, end) in blocks {
            let first = max(0, offset(start)), last = min(dayLength, offset(end))
            if first < last { for minute in first..<last { busy[minute] = true } }
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
    private func rejectSwap(_ state: PlannerState, day: Date, calendar: Calendar, file: StaticString = #filePath, line: UInt = #line) {
        var changed = state
        XCTAssertThrowsError(try changed.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: day, calendar: calendar), file: file, line: line) {
            XCTAssertEqual($0 as? DailyTaskOrderError, .noSpace, file: file, line: line)
        }
        XCTAssertEqual(changed, state, file: file, line: line)
    }

    func testShortenedFloatingWitnessCannotMakeAnImpossibleSwapSucceed() throws {
        let cal = calendar(), day = date(cal)
        let state = try roundTrip(fixture(day: day, calendar: cal))
        rejectSwap(state, day: day, calendar: cal)
    }

    func testJointRetryKeepsActualEventEndAcrossTheMissingHour() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        var state = try roundTrip(fixture(day: day, calendar: cal, end: 300))
        let before = state
        try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: day, calendar: cal)
        XCTAssertEqual(state.tasks.map(\.id), before.tasks.reversed().map(\.id))
        XCTAssertEqual(state.tasks.map(\.durationMinutes), [20, 20])
        XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        XCTAssertTrue(eventsFit(state, tasks: state.tasks, day: day, calendar: cal))
        XCTAssertGreaterThanOrEqual(state.tasks[1].start.timeIntervalSince(state.tasks[0].end), 900)
        XCTAssertLessThanOrEqual(state.tasks[1].end, engine.instant(day: day, minute: 300))
    }

    func testExactAppointmentCannotBeConsumedByTheActualRetry() throws {
        let cal = calendar(), day = date(cal)
        var input = fixture(day: day, calendar: cal, end: 300)
        input.fixedEvents.append(.init(title: "Exact", startMinute: 180, endMinute: 210, startDate: day, endDate: day))
        let state = try roundTrip(input)
        XCTAssertFalse(eventsFit(state, tasks: [], day: day, calendar: cal))
        rejectSwap(state, day: day, calendar: cal)
    }

    func testMultipleFloatingReservationsArePreservedAsCompleteActualSpans() throws {
        let cal = calendar(), day = date(cal), engine = ScheduleEngine(calendar: cal)
        var state = try roundTrip(fixture(day: day, calendar: cal, end: 300, durations: [60, 60]))
        let before = state
        try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: day, calendar: cal)
        XCTAssertEqual(state.tasks.map(\.id), before.tasks.reversed().map(\.id))
        XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        XCTAssertEqual(state.tasks[0].start, engine.instant(day: day, minute: 240))
        XCTAssertEqual(state.tasks[1].start, engine.instant(day: day, minute: 275))
        XCTAssertTrue(eventsFit(state, tasks: state.tasks, day: day, calendar: cal))
        rejectSwap(try roundTrip(fixture(day: day, calendar: cal, end: 300, durations: [60, 61])), day: day, calendar: cal)
    }

    func testSavedOrderUsesTheSameActualWitnessAndFailureKeepsOriginalTasks() throws {
        let cal = calendar(), day = date(cal)
        for end in [240, 300] {
            var state = try roundTrip(fixture(day: day, calendar: cal, end: end))
            state.settings.dailyTaskOrders = [.init(day: day, keys: Array(DailyTaskOrder.keys(for: state.tasks).reversed()))]
            let before = state, result = state.applyingDailyTaskOrders(to: state.tasks, calendar: cal)
            if end == 240 { XCTAssertEqual(result, before.tasks) }
            else {
                XCTAssertEqual(result.map(\.id), before.tasks.reversed().map(\.id))
                XCTAssertTrue(eventsFit(state, tasks: result, day: day, calendar: cal))
            }
            XCTAssertEqual(state, before)
        }
    }

    func testUnsupportedJointCombinationFailsWithoutChangingState() throws {
        let cal = calendar(), day = date(cal)
        let state = try roundTrip(fixture(day: day, calendar: cal, end: 300, durations: Array(repeating: 10, count: 9)))
        rejectSwap(state, day: day, calendar: cal)
    }

    func testHalfHourGapValidatesActualWindowsAtRuntime() throws {
        let cal = calendar("Australia/Lord_Howe"), day = date(cal, month: 10, day: 4)
        var input = fixture(day: day, calendar: cal, end: 270, durations: [45, 60])
        input.fixedEvents[0].startMinute = 120
        input.fixedEvents[0].endMinute = 270
        input.fixedEvents[1].endMinute = 210
        var state = try roundTrip(input)
        if !eventsFit(state, tasks: [], day: day, calendar: cal) { rejectSwap(state, day: day, calendar: cal) }
        else {
            let before = state
            try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: day, calendar: cal)
            XCTAssertTrue(eventsFit(state, tasks: state.tasks, day: day, calendar: cal))
            XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        }
    }

    func testOrdinaryAndRepeatedHourKeepNominalFastPathBehavior() throws {
        for (zone, month, number) in [("UTC", 3, 8), ("America/New_York", 3, 9), ("America/New_York", 11, 1)] {
            let cal = calendar(zone), day = date(cal, month: month, day: number), engine = ScheduleEngine(calendar: cal)
            var state = try roundTrip(fixture(day: day, calendar: cal, end: 300)), before = state
            try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: day, calendar: cal)
            XCTAssertEqual(state.tasks.map(\.id), before.tasks.reversed().map(\.id))
            XCTAssertEqual(state.tasks.map(\.start), [engine.instant(day: day, minute: 60), engine.instant(day: day, minute: 95)])
            XCTAssertEqual(state.fixedEvents, before.fixedEvents)
            XCTAssertTrue(eventsFit(state, tasks: state.tasks, day: day, calendar: cal))
        }
    }

    func testNonmonotoneExactMappingCannotBeBypassedByTheNominalFastPath() throws {
        let cal = calendar("Australia/Lord_Howe"), day = date(cal, month: 10, day: 4), engine = ScheduleEngine(calendar: cal)
        var input = fixture(day: day, calendar: cal, end: 270, durations: [])
        input.settings.availability[0].startMinute = 150
        input.tasks[0].start = engine.instant(day: day, minute: 150)
        input.tasks[1].start = engine.instant(day: day, minute: 185)
        input.fixedEvents = [.init(title: "Exact before missing time", startMinute: 105, endMinute: 120, startDate: day, endDate: day)]
        var state = try roundTrip(input)
        let exactStart = engine.instant(day: day, minute: 105), exactEnd = engine.instant(day: day, minute: 120)
        let first = max(exactEnd, engine.instant(day: day, minute: 150)), end = engine.instant(day: day, minute: 270)
        if first.addingTimeInterval(55 * 60) > end { rejectSwap(state, day: day, calendar: cal) }
        else {
            let before = state
            try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: day, calendar: cal)
            XCTAssertTrue(state.tasks.allSatisfy { $0.end <= exactStart || $0.start >= exactEnd })
            XCTAssertEqual(state.tasks.map(\.id), before.tasks.reversed().map(\.id))
            XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        }
    }

    func testOrdinaryDateMatchesAndroidSwapAndAtomicFailureControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Android/build/tests/daily-floating-date.json")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("Run ./Android/test.sh to generate daily floating controls") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            var state = try JSONDecoder().decode(PlannerState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"])))
            let expected = try JSONDecoder().decode([ScheduledTask].self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(row["tasks"])))
            let now = Date(timeIntervalSinceReferenceDate: try XCTUnwrap(row["now"] as? Double))
            let before = state
            if try XCTUnwrap(row["succeeds"] as? Bool) {
                try state.swapDailyTasks(before.tasks[0].id, before.tasks[1].id, now: now, calendar: calendar("Asia/Shanghai"))
                XCTAssertEqual(state.tasks, expected)
                XCTAssertEqual(state.fixedEvents, before.fixedEvents)
            } else { rejectSwap(state, day: now, calendar: calendar("Asia/Shanghai")) }
        }
    }
}
