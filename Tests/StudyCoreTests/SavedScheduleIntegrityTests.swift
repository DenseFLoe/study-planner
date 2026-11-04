import XCTest
@testable import StudyCore

final class SavedScheduleIntegrityTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    private func date(_ hour: Int = 7, day: Int = 5) -> Date {
        calendar.date(from: .init(year: 2026, month: 11, day: day, hour: hour))!
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = [Course(name: "Course", totalMinutes: 120, startDate: date(), deadline: date(), minimumBlockMinutes: 0)]
        state.settings.minimumScheduleUnit = 60
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 660) }
        _ = state.replan(now: date(), calendar: calendar)
        return state
    }
    private func assertValid(_ state: PlannerState, now: Date? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(ScheduleEngine(calendar: calendar).hasInvalidSavedTasks(state: state, now: now ?? date()), file: file, line: line)
        for course in state.courses {
            XCTAssertLessThanOrEqual(state.tasks.filter { $0.isUnconfirmed && $0.planningEnd > (now ?? date()) && $0.courseID == course.id }.reduce(0) { $0 + $1.durationMinutes }, state.remainingMinutes(for: course), file: file, line: line)
        }
    }
    func testOfflineMergesRepairInEitherOrderAndRepeatedOldRowsStayRemoved() throws {
        let base = fixture()
        var initial = SyncLedger(); try initial.capture(base, now: date())
        var a = initial, b = initial, local = base, remote = base
        a.device = "mac"; b.device = "phone"
        local.settings.minimumScheduleUnit = 30
        _ = local.replan(now: date(), calendar: calendar)
        remote.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 780, endMinute: 960) }
        _ = remote.replan(now: date(), calendar: calendar)
        try a.capture(local, now: date().addingTimeInterval(1))
        try b.capture(remote, now: date().addingTimeInterval(2))
        for rows in [a.changes(after: 0) + b.changes(after: 0), b.changes(after: 0) + a.changes(after: 0)] {
            var ledger = SyncLedger(); try ledger.merge(rows)
            var merged = try ledger.materialize()
            XCTAssertEqual(merged.tasks.reduce(0) { $0 + $1.durationMinutes }, 240)
            XCTAssertFalse(ScheduleEngine(calendar: calendar).assessSavedPlan(state: merged, now: date()).diagnostics.isEmpty)
            XCTAssertTrue(merged.reconcileSavedSchedule(now: date(), calendar: calendar))
            assertValid(merged)
            XCTAssertEqual(merged.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
            XCTAssertTrue(merged.tasks.allSatisfy { $0.start >= date(13) })
            try ledger.capture(merged, now: date().addingTimeInterval(3))
            let sequence = ledger.sequence
            try ledger.merge(rows)
            var repeated = try ledger.materialize()
            XCTAssertFalse(repeated.reconcileSavedSchedule(now: date(), calendar: calendar))
            try ledger.capture(repeated, now: date().addingTimeInterval(4))
            XCTAssertEqual(ledger.sequence, sequence)
            XCTAssertEqual(repeated.tasks, merged.tasks)
        }
    }
    func testLateNewTaskIDsFromLosingInputsAreRepaired() throws {
        var state = fixture()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 780, endMinute: 960) }
        _ = state.replan(now: date(), calendar: calendar)
        let valid = state.tasks
        state.tasks.append(ScheduledTask(courseID: state.courses[0].id, start: date(8), durationMinutes: 30))
        XCTAssertTrue(state.reconcileSavedSchedule(now: date(), calendar: calendar))
        XCTAssertEqual(state.tasks, valid)
    }
    func testFullLegalPlanPreservesDraggedOrderAndFloatingWindows() throws {
        var state = fixture()
        state.courses[0].totalMinutes = 60
        state.courses.append(Course(name: "Other", totalMinutes: 60, startDate: date(), deadline: date()))
        var event = FixedEvent(title: "Floating", startMinute: 480, endMinute: 660, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 30
        state.fixedEvents = [event]
        _ = state.replan(now: date(), calendar: calendar)
        try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(), calendar: calendar)
        let before = state
        XCTAssertFalse(state.reconcileSavedSchedule(now: date(), calendar: calendar))
        XCTAssertEqual(state, before)
    }
    func testRepairKeepsPartialConfirmationHistoryAndRest() throws {
        var state = fixture()
        let task = state.tasks[0]
        let now = date(9)
        try state.confirm(taskID: task.id, actualMinutes: 30, now: now, calendar: calendar)
        let history = state.tasks[0], records = state.completions
        state.tasks.append(ScheduledTask(courseID: task.courseID, start: now, durationMinutes: 90))
        XCTAssertTrue(state.reconcileSavedSchedule(now: now, calendar: calendar))
        XCTAssertEqual(state.tasks.first { $0.id == task.id }, history)
        XCTAssertEqual(state.completions, records)
        XCTAssertTrue(state.tasks.filter(\.isUnconfirmed).allSatisfy { $0.start >= now.addingTimeInterval(900) })
        assertValid(state, now: now)
    }
    func testRepairPreservesImmediateSegmentAndLessonBudget() throws {
        var state = fixture()
        state.courses[0].type = .lessonBasedRecorded
        state.courses[0].totalMinutes = 90
        state.courses[0].deadline = date(day: 6)
        state.courses[0].manualLessons = [.init(id: "one", name: "One", durationMinutes: 90)]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: date(8), calendar: calendar)
        let request = try XCTUnwrap(state.settings.immediateStudy)
        state.tasks.append(ScheduledTask(courseID: state.courses[0].id, start: date(10), durationMinutes: 90, lessonID: "one"))
        XCTAssertTrue(state.reconcileSavedSchedule(now: date(8), calendar: calendar))
        XCTAssertEqual(state.settings.immediateStudy, request)
        XCTAssertEqual(state.tasks.first { $0.id == request.task.id }, request.task)
        assertValid(state, now: date(8))
        XCTAssertFalse(state.reconcileSavedSchedule(now: date(8), calendar: calendar))
    }
}

extension SavedScheduleIntegrityTests {
    func testGeneratedPlansAreStableAcrossMixedWindowsAndLessons() throws {
        for index in 0..<36 {
            var state = fixture()
            state.courses[0].totalMinutes = 30 + (index % 6) * 30
            state.settings.minimumScheduleUnit = [15, 30, 60][index % 3]
            state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600 + (index % 4) * 60) }
            state.courses[0].deadline = date(day: 6)
            if index.isMultiple(of: 2) {
                state.courses[0].type = .lessonBasedRecorded
                state.courses[0].manualLessons = (0..<(index % 6 + 1)).map { .init(id: "\($0)", name: "Lesson \($0)", durationMinutes: 30) }
            }
            var event = FixedEvent(title: "Event", startMinute: 540, endMinute: 660, startDate: date(), endDate: date(day: 6), weekdays: Set(1...7))
            if index.isMultiple(of: 3) { event.floatingDurationMinutes = 30 }
            state.fixedEvents = [event]
            _ = state.replan(now: date(), calendar: calendar)
            assertValid(state)
            let before = state
            XCTAssertFalse(state.reconcileSavedSchedule(now: date(), calendar: calendar), "scenario \(index)")
            XCTAssertEqual(state, before)
        }
    }
}
