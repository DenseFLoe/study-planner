import XCTest
@testable import StudyCore

final class DailyTaskDateIntervalTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func day(_ calendar: Calendar, month: Int = 3, date: Int = 8) -> Date {
        calendar.date(from: .init(year: 2026, month: month, day: date))!
    }
    private func fixture(day: Date, calendar: Calendar, windows: [(Int, Int)],
                         lengths: [Int], starts: [Int]) -> PlannerState {
        var state = PlannerState()
        let course = Course(name: "Synthetic calendar swap", totalMinutes: lengths.reduce(0, +),
                            startDate: day, deadline: day)
        state.courses = [course]
        state.settings.availability = windows.map {
            .init(weekday: calendar.component(.weekday, from: day), startMinute: $0.0, endMinute: $0.1)
        }
        let engine = ScheduleEngine(calendar: calendar)
        state.tasks = zip(lengths, starts).enumerated().map {
            .init(courseID: course.id, start: engine.instant(day: day, minute: $0.element.1),
                  durationMinutes: $0.element.0, lessonID: "lesson-\($0.offset)")
        }
        return state
    }
    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        _ = try PlannerBackup(state: state, reason: "Calendar swap").validated()
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        return try ledger.materialize()
    }
    private func exactFixture() throws -> (PlannerState, Calendar, Date) {
        let cal = calendar(), date = day(cal)
        var state = fixture(day: date, calendar: cal, windows: [(60, 300)], lengths: [60, 90], starts: [60, 210])
        state.fixedEvents = [.init(title: "Exact appointment", startMinute: 180, endMinute: 210,
                                   startDate: date, endDate: date)]
        return (try roundTrip(state), cal, date)
    }

    func testSpringForwardSwapRejectsActualAvailabilityOverflowAtomically() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = try roundTrip(fixture(day: date, calendar: cal, windows: [(60, 180)],
                                         lengths: [100, 5], starts: [60, 70]))
        XCTAssertEqual(engine.instant(day: date, minute: 180).timeIntervalSince(engine.instant(day: date, minute: 60)), 3600)
        let before = state
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id,
                                                     now: state.tasks[0].start, calendar: cal)) {
            XCTAssertEqual($0 as? DailyTaskOrderError, .noSpace)
        }
        XCTAssertEqual(state, before)
    }

    func testSpringForwardSwapCannotBreakAnInitiallyLegalExactEventSchedule() throws {
        var (state, cal, date) = try exactFixture()
        let engine = ScheduleEngine(calendar: cal)
        XCTAssertEqual(state.tasks[0].end, engine.instant(day: date, minute: 180))
        XCTAssertEqual(state.tasks[1].start, engine.instant(day: date, minute: 210))
        XCTAssertEqual(state.tasks[1].end, engine.instant(day: date, minute: 300))
        XCTAssertEqual(state.tasks[1].start.timeIntervalSince(state.tasks[0].end), 1800)
        let before = state
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id,
                                                     now: state.tasks[0].start, calendar: cal)) {
            XCTAssertEqual($0 as? DailyTaskOrderError, .noSpace)
        }
        XCTAssertEqual(state, before)
    }

    func testLargerSpringWindowPreservesFeasibleOrderDurationAndRest() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = try roundTrip(fixture(day: date, calendar: cal, windows: [(60, 300)],
                                         lengths: [100, 5], starts: [60, 70]))
        let original = state.tasks
        try state.swapDailyTasks(original[0].id, original[1].id, now: original[0].start, calendar: cal)
        XCTAssertEqual(state.tasks.map(\.id), [original[1].id, original[0].id])
        XCTAssertEqual(state.tasks.map(\.durationMinutes), [5, 100])
        XCTAssertEqual(state.tasks[0].start, engine.instant(day: date, minute: 60))
        XCTAssertEqual(state.tasks[1].start, engine.instant(day: date, minute: 80))
        XCTAssertEqual(state.tasks[1].end, engine.instant(day: date, minute: 240))
        XCTAssertEqual(state.tasks[1].start.timeIntervalSince(state.tasks[0].end), 900)
    }

    func testNominallySeparatedWindowsMergeWhenTheirActualDatesTouch() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        for windows in [[(60, 150), (180, 240)], [(60, 120), (120, 240)]] {
            var state = try roundTrip(fixture(day: date, calendar: cal, windows: windows,
                                             lengths: [60, 5], starts: [60, 70]))
            let original = state.tasks
            try state.swapDailyTasks(original[0].id, original[1].id, now: original[0].start, calendar: cal)
            XCTAssertEqual(state.tasks.map(\.id), [original[1].id, original[0].id])
            // The Date union admits the original earliest physical candidate;
            // checking each mapped run alone would postpone it until 03:00.
            XCTAssertEqual(state.tasks[1].start, engine.instant(day: date, minute: 80))
            XCTAssertEqual(state.tasks[1].end, engine.instant(day: date, minute: 200))
        }
    }

    func testFloatingMetadataEnclosesActualTaskWithoutCrossingExactGap() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal, windows: [(60, 300)], lengths: [60], starts: [90])
        var floating = FixedEvent(title: "Floating half hour", startMinute: 60, endMinute: 150,
                                  startDate: date, endDate: date)
        floating.floatingDurationMinutes = 30
        let exact = FixedEvent(title: "Exact appointment", startMinute: 210, endMinute: 240,
                               startDate: date, endDate: date)
        state.fixedEvents = [floating, exact]
        state = try roundTrip(state)
        let before = state
        // A real 01:00–01:30 witness leaves 01:30–03:30 for this elapsed hour.
        let placed = try XCTUnwrap(state.placeDailyTasks(state.tasks, earliest: state.tasks[0].start,
            calendar: cal, floatingPlacements: [floating.id: 60]))
        let task = try XCTUnwrap(placed.first)
        XCTAssertEqual(task.start, engine.instant(day: date, minute: 90))
        XCTAssertEqual(task.end, engine.instant(day: date, minute: 210))
        XCTAssertEqual(task.planningStart, engine.instant(day: date, minute: 60))
        XCTAssertEqual(task.planningEnd, task.end)
        XCTAssertLessThanOrEqual(task.planningEnd, engine.instant(day: date, minute: exact.startMinute))
        XCTAssertEqual(task.durationMinutes, 60)
        XCTAssertEqual(state, before)
    }

    func testSavedOrderKeepsLegalScheduleWhenReorderingWouldCrossExactEvent() throws {
        var (state, cal, date) = try exactFixture()
        state.settings.dailyTaskOrders = [.init(day: date, keys: Array(DailyTaskOrder.keys(for: state.tasks).reversed()))]
        let before = state
        XCTAssertEqual(state.applyingDailyTaskOrders(to: state.tasks, calendar: cal), before.tasks)
        XCTAssertEqual(state, before)
    }

    func testFallBackAndUTCKeepPhysicalDurationsAndRest() throws {
        for (zone, month, dateNumber) in [("America/New_York", 11, 1), ("UTC", 3, 8)] {
            let cal = calendar(zone), date = day(cal, month: month, date: dateNumber), engine = ScheduleEngine(calendar: cal)
            var state = try roundTrip(fixture(day: date, calendar: cal, windows: [(60, 240)],
                                             lengths: [60, 30], starts: [60, 135]))
            let original = state.tasks
            try state.swapDailyTasks(original[0].id, original[1].id, now: original[0].start, calendar: cal)
            XCTAssertEqual(state.tasks.map(\.id), [original[1].id, original[0].id])
            XCTAssertEqual(state.tasks.map(\.durationMinutes), [30, 60])
            XCTAssertEqual(state.tasks[0].start, engine.instant(day: date, minute: 60))
            XCTAssertEqual(state.tasks[1].start.timeIntervalSince(state.tasks[0].end), 900)
            XCTAssertEqual(state.tasks[1].end.timeIntervalSince(state.tasks[1].start), 3600)
            XCTAssertLessThanOrEqual(state.tasks[1].end, engine.instant(day: date, minute: 240))
        }
    }

    func testSpringForwardSwapCannotSpillPastActualMidnight() throws {
        let cal = calendar(), date = day(cal)
        var state = try roundTrip(fixture(day: date, calendar: cal, windows: [(0, 1440)],
                                         lengths: [60, 1320], starts: [0, 75]))
        let before = state
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date, calendar: cal)) {
            XCTAssertEqual($0 as? DailyTaskOrderError, .noSpace)
        }
        XCTAssertEqual(state, before)
    }

    func testWholeDayPlacementUsesActualNextMidnight() throws {
        for (zone, duration, fits) in [("America/New_York", 1440, false),
                                      ("America/New_York", 1380, true), ("UTC", 1440, true)] {
            let cal = calendar(zone), date = day(cal), engine = ScheduleEngine(calendar: cal)
            let state = try roundTrip(fixture(day: date, calendar: cal, windows: [(0, 1440)],
                                              lengths: [duration], starts: [0]))
            let before = state
            let placed = state.placeDailyTasks(state.tasks, earliest: date, calendar: cal)
            if fits {
                let task = try XCTUnwrap(placed?.first)
                XCTAssertEqual(task, state.tasks[0])
                XCTAssertEqual(task.end, engine.instant(day: date, minute: 1440))
            } else {
                XCTAssertNil(placed)
            }
            XCTAssertEqual(state, before)
        }
    }
}
