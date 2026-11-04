import XCTest
@testable import StudyCore

final class ImmediateDateIntervalTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }
    private func day(_ cal: Calendar, month: Int = 3, date: Int = 8) -> Date {
        cal.date(from: .init(year: 2026, month: month, day: date))!
    }
    private func fixture(day: Date, calendar: Calendar, minutes: Int = 90, window: (Int, Int) = (60, 300)) -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "Synthetic immediate dates", totalMinutes: minutes, startDate: day, deadline: day)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "selected", name: "Selected lesson", durationMinutes: minutes)]
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: window.0, endMinute: window.1) }
        return state
    }
    private func roundTrip(_ state: PlannerState) throws -> PlannerState {
        _ = try PlannerBackup(state: state, reason: "Immediate date constraints").validated()
        var ledger = SyncLedger()
        try ledger.capture(state)
        _ = try CloudArchive(ledger: ledger).validated()
        return try ledger.materialize()
    }

    func testSpringAvailabilityChoosesActualSegmentAndPreservesContinuationProgress() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal, minutes: 100, window: (60, 180))
        state.courses[0].deadline = cal.date(byAdding: .day, value: 1, to: date)!
        let course = state.courses[0], now = engine.instant(day: date, minute: 60)
        let result = try state.studyImmediately(courseID: course.id, now: now, calendar: cal)
        let first = try XCTUnwrap(state.settings.immediateStudy?.task)
        XCTAssertEqual(first.durationMinutes, 60)
        XCTAssertEqual(first.end, engine.instant(day: date, minute: 180))
        XCTAssertEqual(state.settings.immediateStudy?.continuesLesson, true)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 100)
        XCTAssertEqual(state.remainingMinutes(for: course), 100)
        XCTAssertTrue(state.completions.isEmpty)
        state = try roundTrip(state)
        XCTAssertEqual(state.replan(now: now.addingTimeInterval(300), calendar: cal).tasks.first, first)
        try state.confirm(taskID: first.id, actualMinutes: 60, now: first.end, calendar: cal)
        XCTAssertEqual(state.remainingMinutes(for: course), 40)
        XCTAssertEqual(state.immediateStudyContinuation(now: first.end, calendar: cal)?.remainingMinutes, 40)
        let continued = state.replan(now: first.end.addingTimeInterval(900), calendar: cal)
        XCTAssertEqual(continued.tasks.reduce(0) { $0 + $1.durationMinutes }, 40)
        XCTAssertTrue(continued.tasks.allSatisfy { $0.lessonID == "selected" })
    }

    func testActualExactAndFloatingConstraintsShortenTheFirstSegment() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        for floating in [false, true] {
            var state = fixture(day: date, calendar: cal)
            var event = FixedEvent(title: "Actual half hour", startMinute: 180, endMinute: 210, startDate: date, endDate: date)
            if floating { event.floatingDurationMinutes = 30 }
            state.fixedEvents = [event]
            let course = state.courses[0]
            let result = try state.studyImmediately(courseID: course.id, now: engine.instant(day: date, minute: 60), calendar: cal)
            let task = try XCTUnwrap(state.settings.immediateStudy?.task)
            XCTAssertEqual(task.durationMinutes, 60)
            XCTAssertEqual(task.end, engine.instant(day: date, minute: 180))
            XCTAssertEqual(state.settings.immediateStudy?.continuesLesson, true)
            XCTAssertEqual(state.remainingMinutes(for: course), 90)
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 90)
            XCTAssertTrue(result.tasks.allSatisfy { $0.end <= engine.instant(day: date, minute: 180) || $0.start >= engine.instant(day: date, minute: 210) })
            XCTAssertEqual(state.fixedEvents, [event])
            XCTAssertNotNil(state.validImmediateStudyTask(now: engine.instant(day: date, minute: 75), calendar: cal))
        }
    }

    func testCrossedGapPinKeepsItsActualEndOnRefresh() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal)
        let now = engine.instant(day: date, minute: 60)
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: now, calendar: cal)
        let task = try XCTUnwrap(state.settings.immediateStudy?.task)
        XCTAssertEqual(task.durationMinutes, 90)
        XCTAssertEqual(task.end, engine.instant(day: date, minute: 210))
        let nominal = try XCTUnwrap(state.immediateStudyReservation(task, calendar: cal).nominalEvent)
        XCTAssertEqual(engine.instant(day: date, minute: nominal.startMinute), task.start)
        XCTAssertEqual(engine.instant(day: date, minute: nominal.endMinute), task.end)
        state = try roundTrip(state)
        let refreshed = state.replan(now: now.addingTimeInterval(300), calendar: cal)
        XCTAssertEqual(refreshed.tasks.filter { $0.id == task.id }, [task])
        XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 90)
        state.fixedEvents = [.init(title: "New actual conflict", startMinute: 180, endMinute: 210, startDate: date, endDate: date)]
        XCTAssertNil(state.validImmediateStudyTask(now: now.addingTimeInterval(300), calendar: cal))
    }

    func testRepeatedHourSupportsARealIntervalWithEqualClockEndpoints() throws {
        let cal = calendar(), date = day(cal, month: 11, date: 1), engine = ScheduleEngine(calendar: cal)
        let now = engine.instant(day: date, minute: 90)
        var state = fixture(day: date, calendar: cal, minutes: 60, window: (60, 120))
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: now, calendar: cal)
        let task = try XCTUnwrap(state.settings.immediateStudy?.task)
        XCTAssertEqual(task.start, now)
        XCTAssertEqual(task.durationMinutes, 60)
        XCTAssertEqual(task.end, now.addingTimeInterval(3600))
        XCTAssertEqual(cal.component(.hour, from: task.start), cal.component(.hour, from: task.end))
        XCTAssertEqual(cal.component(.minute, from: task.start), cal.component(.minute, from: task.end))
        XCTAssertNil(state.immediateStudyReservation(task, calendar: cal).nominalEvent)
        XCTAssertEqual(result.tasks, [task])
        XCTAssertNil(state.settings.immediateStudy?.continuesLesson)
        state = try roundTrip(state)
        XCTAssertEqual(state.replan(now: now.addingTimeInterval(600), calendar: cal).tasks, [task])
    }

    func testSecondRepeatedHourKeepsTheAbsoluteRoundedStart() throws {
        let cal = calendar(), date = day(cal, month: 11, date: 1), engine = ScheduleEngine(calendar: cal)
        let now = engine.instant(day: date, minute: 90).addingTimeInterval(3614)
        let rounded = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 60) * 60)
        var state = fixture(day: date, calendar: cal, minutes: 60, window: (60, 180))
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: now, calendar: cal)
        let task = try XCTUnwrap(state.settings.immediateStudy?.task)
        XCTAssertEqual(task.start, rounded)
        XCTAssertEqual(state.settings.actualStudyStart, rounded)
        XCTAssertNil(state.immediateStudyReservation(task, calendar: cal).nominalEvent)
        XCTAssertEqual(task.durationMinutes, 60)
        XCTAssertEqual(result.tasks, [task])
        state = try roundTrip(state)
        XCTAssertEqual(state.replan(now: rounded.addingTimeInterval(300), calendar: cal).tasks, [task])
        XCTAssertEqual(state.settings.actualStudyStart, rounded)
    }

    func testOtherTaskSwapPreservesAnUnrepresentablePinAndFloatingConstraint() throws {
        let cal = calendar(), date = day(cal, month: 11, date: 1), engine = ScheduleEngine(calendar: cal)
        let now = engine.instant(day: date, minute: 90)
        var state = fixture(day: date, calendar: cal, minutes: 60, window: (0, 240))
        let selected = state.courses[0].id
        state.courses.append(.init(name: "Other course", totalMinutes: 40, startDate: date, deadline: date, minimumBlockMinutes: 20))
        var event = FixedEvent(title: "Floating fixed-length window", startMinute: 165, endMinute: 195, startDate: date, endDate: date)
        event.floatingDurationMinutes = 30
        state.fixedEvents = [event]
        _ = try state.studyImmediately(courseID: selected, now: now, calendar: cal)
        let pinned = try XCTUnwrap(state.settings.immediateStudy?.task)
        let others = state.tasks.filter { $0.courseID != selected }
        guard others.count == 2 else { XCTFail("The real pinned interval leaves room for both other tasks"); return }
        try state.swapDailyTasks(others[0].id, others[1].id, now: now, calendar: cal)
        XCTAssertEqual(state.tasks.first { $0.id == pinned.id }, pinned)
        let moved = state.tasks.filter { $0.courseID != selected }
        XCTAssertEqual(moved.map(\.id), others.reversed().map(\.id))
        XCTAssertTrue(moved.allSatisfy { $0.start >= pinned.end.addingTimeInterval(900) })
        XCTAssertTrue(state.tasks.allSatisfy { $0.end <= engine.instant(day: date, minute: 165) || $0.start >= engine.instant(day: date, minute: 195) })
        XCTAssertEqual(state.fixedEvents, [event])
    }

    func testRealHistoryRestAndNoSpaceFailureStayAtomicAcrossTheGap() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal, window: (60, 180))
        let historyCourse = Course(name: "Confirmed history", totalMinutes: 60, startDate: date, deadline: date)
        state.courses.append(historyCourse)
        let previous = ScheduledTask(courseID: historyCourse.id, start: date, durationMinutes: 60)
        state.tasks = [previous]
        try state.confirm(taskID: previous.id, actualMinutes: 60, now: engine.instant(day: date, minute: 60), calendar: cal)
        let before = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: engine.instant(day: date, minute: 70), calendar: cal)) {
            XCTAssertEqual($0 as? ImmediateStudyError, .noSpace)
        }
        XCTAssertEqual(state, before)
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: engine.instant(day: date, minute: 75), calendar: cal)
        XCTAssertEqual(state.settings.immediateStudy?.task.durationMinutes, 45)
        XCTAssertEqual(state.tasks.first { $0.id == previous.id }, before.tasks.first { $0.id == previous.id })
        XCTAssertEqual(state.completions, before.completions)
    }

    func testOrdinaryAndMidnightControlsKeepExistingTaskLimit() throws {
        for (zone, minutes, window, startMinute, expected) in [
            ("UTC", 90, (60, 300), 60, 90),
            ("Asia/Shanghai", 90, (60, 300), 60, 90),
            ("UTC", 90, (1380, 1440), 1410, 30),
            ("America/New_York", 1500, (0, 1440), 0, 1440)
        ] {
            let cal = calendar(zone), date = day(cal, month: 11, date: 1), engine = ScheduleEngine(calendar: cal)
            var state = fixture(day: date, calendar: cal, minutes: minutes, window: window)
            let result = try state.studyImmediately(courseID: state.courses[0].id, now: engine.instant(day: date, minute: startMinute), calendar: cal)
            XCTAssertEqual(state.settings.immediateStudy?.task.durationMinutes, expected)
            XCTAssertLessThanOrEqual(try XCTUnwrap(state.settings.immediateStudy?.task.end), engine.instant(day: date, minute: 1440))
            XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), minutes)
            XCTAssertTrue(result.tasks.contains { $0.id == state.settings.immediateStudy?.task.id })
            _ = try PlannerBackup(state: state, reason: "Daily task limit").validated()
        }
    }

    func testAdjacentAndOverlappingActualAvailabilityFormsOneContinuousWindow() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        for windows in [[(60, 120), (120, 300)], [(60, 210), (180, 300)]] {
            var state = fixture(day: date, calendar: cal, minutes: 100)
            state.settings.availability = windows.map { .init(weekday: cal.component(.weekday, from: date), startMinute: $0.0, endMinute: $0.1) }
            let originalWindows = state.settings.availability
            _ = try state.studyImmediately(courseID: state.courses[0].id, now: engine.instant(day: date, minute: 60), calendar: cal)
            XCTAssertEqual(state.settings.immediateStudy?.task.durationMinutes, 100)
            XCTAssertEqual(state.settings.availability, originalWindows)
        }
    }

    func testHalfHourMissingTimeUsesActualExactBoundaryAndRejectsAtomically() throws {
        let cal = calendar("Australia/Lord_Howe"), date = day(cal, month: 10, date: 4), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal, minutes: 60, window: (150, 270))
        state.fixedEvents = [.init(title: "Actual exact boundary", startMinute: 105, endMinute: 120, startDate: date, endDate: date)]
        let now = engine.instant(day: date, minute: 150), exactStart = engine.instant(day: date, minute: 105), exactEnd = engine.instant(day: date, minute: 120)
        let before = state
        if exactStart <= now && now < exactEnd {
            XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: now, calendar: cal)) {
                XCTAssertEqual($0 as? ImmediateStudyError, .noSpace)
            }
            XCTAssertEqual(state, before)
        } else {
            _ = try state.studyImmediately(courseID: state.courses[0].id, now: now, calendar: cal)
            let task = try XCTUnwrap(state.settings.immediateStudy?.task)
            XCTAssertEqual(task.durationMinutes, 60)
            XCTAssertTrue(task.end <= exactStart || task.start >= exactEnd)
            XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        }
    }

    func testExpiredUnconfirmedDSTSegmentDoesNotCreditProgress() throws {
        let cal = calendar(), date = day(cal), engine = ScheduleEngine(calendar: cal)
        var state = fixture(day: date, calendar: cal, minutes: 100, window: (60, 180))
        state.courses[0].deadline = cal.date(byAdding: .day, value: 1, to: date)!
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: engine.instant(day: date, minute: 60), calendar: cal)
        state = try roundTrip(state)
        let now = engine.instant(day: date, minute: 185)
        let result = state.replan(now: now, calendar: cal)
        XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 100)
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertEqual(state.settings.immediateStudy?.continuesLesson, true)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 100)
        XCTAssertTrue(result.tasks.allSatisfy { $0.start >= now && $0.lessonID == "selected" })
    }
}
