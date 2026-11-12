import XCTest
@testable import StudyCore

final class TaskReschedulingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    private func date(_ day: Int = 12, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "合成数学", totalMinutes: 180, startDate: date(), deadline: date(15))
        course.type = .lessonBasedRecorded
        course.manualLessons = (1...3).map { .init(id: "lesson-\($0)", name: "第\($0)节", durationMinutes: 60) }
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        state.tasks = [date(12, 8), date(12, 9, 15), date(13, 8)].enumerated().map {
            ScheduledTask(courseID: course.id, start: $0.element, durationMinutes: 60, status: $0.offset == 2 ? .future : .planned, lessonID: "lesson-\($0.offset + 1)", lessonName: "第\($0.offset + 1)节")
        }
        return state
    }
    func testMovesExactlyOneLessonAndPreservesEverythingElse() throws {
        var state = fixture(); let before = state, source = state.tasks[0]
        try state.moveTask(source.id, to: date(13), now: date(12, 7), calendar: calendar)
        var expected = before; expected.tasks[0].start = date(13, 9, 15); expected.tasks[0].status = .future
        XCTAssertEqual(state, expected)
        XCTAssertFalse(ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: state, now: date(12, 7)))
        _ = state.prepareSavedScheduleForOpen(now: date(12, 7), calendar: calendar)
        XCTAssertEqual(state, expected, "Reopening must preserve the single-task move")
        var ledger = SyncLedger(); try ledger.capture(state)
        var synced = try ledger.materialize()
        XCTAssertFalse(synced.reconcileSavedSchedule(now: date(12, 7), calendar: calendar))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: synced.tasks.map { ($0.id, $0) }), Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.id, $0) }))
    }
    func testExplicitTimeAndFixedEventGap() throws {
        var state = fixture()
        state.fixedEvents = [.init(title: "合成事项", startMinute: 555, endMinute: 600, startDate: date(13), endDate: date(13))]
        let source = state.tasks[0].id
        try state.moveTask(source, to: date(13), now: date(12, 7), calendar: calendar)
        XCTAssertEqual(state.tasks[0].start, date(13, 10))
        try state.moveTask(source, to: date(13), startMinute: 660, now: date(12, 7), calendar: calendar)
        XCTAssertEqual(state.tasks[0].start, date(13, 11))
        let before = state
        for minute in [480, 540, 555, 1050, 1440, -1] {
            XCTAssertThrowsError(try state.moveTask(source, to: date(13), startMinute: minute, now: date(12, 7), calendar: calendar))
            XCTAssertEqual(state, before)
        }
    }
    func testRejectsInvalidDatesConfirmedHistoryAndPinnedContinuation() throws {
        for variant in 0..<6 {
            var state = fixture()
            if variant == 0 { state.tasks[0].confirmedAt = date(12, 9); state.tasks[0].status = .completed }
            if variant == 1 { state.tasks[0].completedMinutes = 1 }
            if variant == 2 { state.completions = [.init(courseID: state.courses[0].id, taskID: state.tasks[0].id, minutes: 0, recordedAt: date(12, 7))] }
            if variant == 3 { state.settings.immediateStudy = .init(task: state.tasks[0]) }
            if variant == 4 { var pin = state.tasks[0]; pin.id = UUID(); state.settings.immediateStudy = .init(task: pin, continuesLesson: true) }
            if variant == 5 { state.courses[0].autoScheduleEnabled = false }
            let before = state
            XCTAssertThrowsError(try state.moveTask(state.tasks[0].id, to: date(13), now: date(12, 7), calendar: calendar))
            XCTAssertEqual(state, before)
        }
        var state = fixture(); let before = state
        for target in [date(11), date(16)] {
            XCTAssertThrowsError(try state.moveTask(state.tasks[0].id, to: target, now: date(12, 7), calendar: calendar))
            XCTAssertEqual(state, before)
        }
        XCTAssertThrowsError(try state.moveTask(UUID(), to: date(13), now: date(12, 7), calendar: calendar))
    }
    func testElapsedUnconfirmedTaskCanMoveUnlessAlreadyRedistributed() throws {
        var state = fixture()
        try state.moveTask(state.tasks[0].id, to: date(13), now: date(12, 12), calendar: calendar)
        XCTAssertEqual(state.tasks[0].start, date(13, 9, 15))
        state = fixture()
        var duplicate = state.tasks[0]; duplicate.id = UUID(); duplicate.start = date(14, 8); state.tasks.append(duplicate)
        let before = state
        XCTAssertThrowsError(try state.moveTask(state.tasks[0].id, to: date(13), now: date(12, 12), calendar: calendar))
        XCTAssertEqual(state, before)
    }
    func testFloatingEventsNeedJointSpaceWithUnchangedTasks() throws {
        var state = fixture()
        var event = FixedEvent(title: "合成浮动事项", startMinute: 480, endMinute: 660, startDate: date(13), endDate: date(13))
        event.floatingDurationMinutes = 60; state.fixedEvents = [event]
        try state.moveTask(state.tasks[0].id, to: date(13), now: date(12, 7), calendar: calendar)
        XCTAssertEqual(state.tasks[0].start, date(13, 10, 15))
        XCTAssertFalse(state.tasks[0].isFloating)
        state = fixture(); state.fixedEvents = [event]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let before = state
        XCTAssertThrowsError(try state.moveTask(state.tasks[0].id, to: date(13), now: date(12, 7), calendar: calendar))
        XCTAssertEqual(state, before)
    }
    func testTodayPlacementReservesTimeToConfirmAndNoPastTime() throws {
        var state = fixture()
        try state.moveTask(state.tasks[0].id, to: date(), now: date(12, 10, 30), calendar: calendar)
        XCTAssertEqual(state.tasks[0].start, date(12, 10, 31))
        XCTAssertEqual(state.tasks[0].status, .planned)
        XCTAssertThrowsError(try state.moveTask(state.tasks[0].id, to: date(), startMinute: 630, now: date(12, 10, 30), calendar: calendar))
    }
    func testReopenStillRedistributesOverdueWorkAndRepairsInvalidPlan() throws {
        var state = fixture()
        _ = state.prepareSavedScheduleForOpen(now: date(13, 7), calendar: calendar)
        XCTAssertEqual(state.tasks.filter { $0.isUnconfirmed && $0.planningEnd > date(13, 7) }.reduce(0) { $0 + $1.durationMinutes }, 180)
        state = fixture(); state.tasks[0].start = date(13, 8)
        _ = state.prepareSavedScheduleForOpen(now: date(12, 7), calendar: calendar)
        XCTAssertFalse(ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: state, now: date(12, 7)))
    }

    func testDateRolloverKeepsTomorrowMoveWithoutOverdueWork() throws {
        var state = fixture()
        state.courses[0].totalMinutes = 60
        state.courses[0].manualLessons = Array(state.courses[0].manualLessons!.prefix(1))
        state.tasks = [state.tasks[0]]
        try state.moveTask(state.tasks[0].id, to: date(13), startMinute: 660, now: date(12, 7), calendar: calendar)
        var saved = state; saved.tasks[0].status = .planned
        _ = state.prepareSavedScheduleForOpen(now: date(13, 7), calendar: calendar)
        XCTAssertEqual(state, saved)
    }

    func testExplicitClockTimeAcrossDaylightSavingTransition() throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        func instant(_ month: Int, _ day: Int, _ hour: Int) -> Date {
            c.date(from: .init(year: 2026, month: month, day: day, hour: hour))!
        }
        var state = PlannerState()
        let course = Course(name: "合成时区", totalMinutes: 60, startDate: instant(10, 31, 0), deadline: instant(11, 2, 0))
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 0, endMinute: 600) }
        state.tasks = [ScheduledTask(courseID: course.id, start: instant(10, 31, 8), durationMinutes: 60)]
        try state.moveTask(state.tasks[0].id, to: instant(11, 1, 0), startMinute: 180, now: instant(10, 31, 7), calendar: c)
        XCTAssertEqual(state.tasks[0].start, instant(11, 1, 3))
        XCTAssertEqual(state.tasks[0].end.timeIntervalSince(state.tasks[0].start), 3600)
    }
}
