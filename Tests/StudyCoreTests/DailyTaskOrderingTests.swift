import XCTest
@testable import StudyCore

final class DailyTaskOrderingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    private func date(_ hour: Int = 0, day: Int = 5, minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = [Course(name: "数学", totalMinutes: 60, startDate: date(), deadline: date()),
                         Course(name: "英语", totalMinutes: 90, startDate: date(), deadline: date()),
                         Course(name: "政治", totalMinutes: 45, startDate: date(), deadline: date())]
        state.tasks = [ScheduledTask(courseID: state.courses[0].id, start: date(8), durationMinutes: 60),
                       ScheduledTask(courseID: state.courses[1].id, start: date(9, minute: 15), durationMinutes: 90),
                       ScheduledTask(courseID: state.courses[2].id, start: date(11), durationMinutes: 45)]
        return state
    }
    func testNonAdjacentSwapPreservesDurationsIDsAndOtherDays() throws {
        var state = fixture()
        let future = ScheduledTask(courseID: state.courses[0].id, start: date(8, day: 6), durationMinutes: 60)
        state.tasks.append(future)
        let original = state.tasks
        try state.swapDailyTasks(original[0].id, original[2].id, now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.id), [original[2].id, original[1].id, original[0].id, future.id])
        XCTAssertEqual(state.tasks.map(\.durationMinutes), [45, 90, 60, 60])
        XCTAssertEqual(state.tasks.last, future)
        for pair in zip(state.tasks.prefix(2), state.tasks.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.start.timeIntervalSince(pair.0.end), 900)
        }
    }
    func testOrderSurvivesCodingAndRepeatedReplan() throws {
        var state = fixture()
        _ = state.replan(now: date(7), calendar: calendar)
        let original = state.tasks
        let target = original.last { $0.courseID != original[0].courseID }!
        try state.swapDailyTasks(original[0].id, target.id, now: date(7), calendar: calendar)
        let order = state.tasks.map(\.courseID)
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        _ = state.replan(now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.courseID), order)
        let firstReplan = state.tasks
        _ = state.replan(now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks, firstReplan)
    }
    func testFixedEventStaysPinnedAndInsufficientSpaceRollsBack() throws {
        var state = fixture()
        state.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 765)]
        state.fixedEvents = [.init(title: "固定课", startMinute: 540, endMinute: 600,
                                  startDate: date(), endDate: date(), weekdays: [2])]
        state.tasks[1].start = date(10)
        state.tasks[2].start = date(11, minute: 45)
        let before = state
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(7), calendar: calendar))
        XCTAssertEqual(state, before)
        state.settings.availability[0].endMinute = 1080
        try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(7), calendar: calendar)
        XCTAssertEqual(state.fixedEvents, before.fixedEvents)
        XCTAssertTrue(state.tasks.allSatisfy { $0.end <= date(9) || $0.start >= date(10) })
    }
    func testInvalidTargetsDoNotMutateState() {
        var state = fixture()
        let before = state
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[0].id, now: date(7), calendar: calendar))
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(7, day: 6), calendar: calendar))
        XCTAssertEqual(state, before)
        state.tasks[1].confirmedAt = date(7)
        XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(7), calendar: calendar))
    }
    func testFloatingWindowAndRepeatedSwaps() throws {
        var state = fixture()
        state.fixedEvents = [.init(title: "浮动事项", startMinute: 480, endMinute: 720,
                                  startDate: date(), endDate: date(), weekdays: [2])]
        state.fixedEvents[0].floatingDurationMinutes = 30
        let ids = state.tasks.map(\.id)
        try state.swapDailyTasks(ids[0], ids[1], now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.id), [ids[1], ids[0], ids[2]])
        XCTAssertTrue(state.tasks[0].isFloating)
        XCTAssertEqual(state.tasks[0].planningStart, date(8))
        try state.swapDailyTasks(ids[0], ids[1], now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.id), ids)
    }
    private func eveningFixture() -> PlannerState {
        var state = PlannerState()
        state.settings.availability = [.init(weekday: 2, startMinute: 9 * 60, endMinute: 22 * 60)]
        state.courses = [Course(name: "合成课一", totalMinutes: 49, startDate: date(), deadline: date()),
                         Course(name: "合成课二", totalMinutes: 69, startDate: date(), deadline: date(), minimumBlockMinutes: 69),
                         Course(name: "合成课三", totalMinutes: 35, startDate: date(), deadline: date())]
        let unconfirmed = [ScheduledTask(courseID: state.courses[0].id, start: date(18, minute: 21), durationMinutes: 49),
                           ScheduledTask(courseID: state.courses[1].id, start: date(19, minute: 25), durationMinutes: 69),
                           ScheduledTask(courseID: state.courses[2].id, start: date(20, minute: 49), durationMinutes: 35)]
        let completedCourse = Course(name: "已完成的合成课", totalMinutes: 108, startDate: date(day: 4), deadline: date())
        state.courses.append(completedCourse)
        var history = ScheduledTask(courseID: completedCourse.id, start: date(15, minute: 57), durationMinutes: 108)
        history.status = .completed
        history.completedMinutes = 108
        history.confirmedAt = date(13, day: 4)
        history.floatingWindowStart = date(15, minute: 57)
        history.floatingWindowEnd = date(19, minute: 40)
        state.tasks = unconfirmed + [history]
        state.completions = [.init(courseID: history.courseID, taskID: history.id, minutes: 108, recordedAt: history.confirmedAt!)]
        return state
    }

    /// A completed task keeps its recorded floating window as history, but that window is
    /// already resolved and must not reserve the evening slots the swap needs.
    func testPreviouslyConfirmedFloatingHistoryDoesNotBlockEveningSwaps() throws {
        let original = eveningFixture()
        let history = original.tasks.last!
        let unconfirmed = original.tasks.filter(\.isUnconfirmed)
        let ids = unconfirmed.map(\.id)
        let durations = Dictionary(uniqueKeysWithValues: unconfirmed.map { ($0.id, $0.durationMinutes) })
        for (a, b) in [(0, 1), (0, 2), (1, 2)] {
            var swapped = original
            XCTAssertNoThrow(try swapped.swapDailyTasks(ids[a], ids[b], now: date(18), calendar: calendar))
            var expected = ids
            expected.swapAt(a, b)
            let day = swapped.tasks.filter(\.isUnconfirmed).sorted { $0.start < $1.start }
            XCTAssertEqual(day.map(\.id), expected)
            XCTAssertEqual(day.map(\.durationMinutes), expected.map { durations[$0]! })
            XCTAssertEqual(day.first?.start, date(18, minute: 21))
            XCTAssertEqual(day.last?.end, date(21, minute: 24))
            for (previous, next) in zip(day, day.dropFirst()) {
                XCTAssertEqual(next.start.timeIntervalSince(previous.end), 900)
            }
            XCTAssertEqual(swapped.tasks.first { $0.id == history.id }, history)
        }
    }

    func testSameDayConfirmationReservesActualHistoryAndRest() throws {
        for status in [TaskStatus.completed, .partial] {
            var state = eveningFixture()
            state.tasks[3].confirmedAt = date(18, minute: 40)
            state.tasks[3].status = status
            if status == .partial { state.tasks[3].completedMinutes = 30 }
            let history = state.tasks[3]
            let ids = state.tasks.prefix(3).map(\.id)
            try state.swapDailyTasks(ids[0], ids[1], now: date(18, minute: 45), calendar: calendar)
            let placed = state.tasks.filter(\.isUnconfirmed)
            XCTAssertEqual(placed.map(\.id), [ids[1], ids[0], ids[2]])
            XCTAssertEqual(placed.first?.start, date(18, minute: 55))
            XCTAssertEqual(placed.last?.end, date(21, minute: 58))
            XCTAssertEqual(state.tasks.first { $0.id == history.id }, history)
        }
    }

    func testUnresolvedOrLateConfirmedHistoryStillRejectsWhenNoSpace() {
        for confirmedAt in [nil, date(19, minute: 55)] as [Date?] {
            var state = eveningFixture()
            state.tasks[3].confirmedAt = confirmedAt
            let before = state
            XCTAssertThrowsError(try state.swapDailyTasks(state.tasks[0].id, state.tasks[1].id, now: date(18), calendar: calendar)) {
                XCTAssertEqual($0 as? DailyTaskOrderError, .noSpace)
            }
            XCTAssertEqual(state, before)
        }
    }

    func testEveningOrderSurvivesReplanWithPreviouslyConfirmedHistory() throws {
        var state = eveningFixture()
        state.settings.actualStudyStart = date(18, minute: 21)
        let history = state.tasks.last!
        let originalCourses = state.courses
        let completions = state.completions
        _ = state.replan(now: date(18, minute: 21), calendar: calendar)
        let tasks = state.tasks.filter(\.isUnconfirmed)
        XCTAssertEqual(tasks.count, 3)
        try state.swapDailyTasks(tasks[0].id, tasks[2].id, now: date(18, minute: 21), calendar: calendar)
        let ordered = state.tasks.filter(\.isUnconfirmed)
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        for _ in 0..<2 {
            let result = state.replan(now: date(18, minute: 21), calendar: calendar)
            XCTAssertEqual(result.tasks.map(\.courseID), ordered.map(\.courseID))
            XCTAssertEqual(result.tasks.map(\.start), ordered.map(\.start))
            XCTAssertEqual(result.tasks.map(\.durationMinutes), ordered.map(\.durationMinutes))
            XCTAssertEqual(state.tasks.first { $0.id == history.id }, history)
            XCTAssertEqual(state.courses, originalCourses)
            XCTAssertEqual(state.completions, completions)
        }
    }
    func testReplanAfterAnOrderedTaskEndsHasUniqueIDs() throws {
        var state = fixture()
        _ = state.replan(now: date(7), calendar: calendar)
        let original = state.tasks
        let target = original.last { $0.courseID != original[0].courseID }!
        try state.swapDailyTasks(original[0].id, target.id, now: date(7), calendar: calendar)
        _ = state.replan(now: date(7), calendar: calendar)
        let ended = state.tasks[0]
        _ = state.replan(now: ended.end.addingTimeInterval(60), calendar: calendar)
        XCTAssertEqual(Set(state.tasks.map(\.id)).count, state.tasks.count)
        XCTAssertEqual(state.tasks.first(where: { $0.id == ended.id }), ended)
    }
    func testLessonsInSameCourseCanSwapAndSurviveReplan() throws {
        var state = PlannerState()
        var course = Course(name: "高数整套课", totalMinutes: 180, startDate: date(), deadline: date())
        course.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 60),
                                .init(id: "second", name: "第二节", durationMinutes: 60),
                                .init(id: "third", name: "第三节", durationMinutes: 60)]
        course.type = .lessonBasedRecorded
        state.courses = [course]
        _ = state.replan(now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.count, 3)
        let originalLessons = state.tasks.map(\.lessonID)
        let courseBefore = state.courses
        try state.swapDailyTasks(state.tasks[0].id, state.tasks[2].id, now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.lessonID), [originalLessons[2], originalLessons[1], originalLessons[0]])
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        _ = state.replan(now: date(7), calendar: calendar)
        XCTAssertEqual(state.tasks.map(\.lessonID), [originalLessons[2], originalLessons[1], originalLessons[0]])
        XCTAssertEqual(state.courses, courseBefore)
    }

    func testOldSettingsWithoutOrderDecode() throws {
        let data = try JSONEncoder().encode(AppSettings())
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(decoded.dailyTaskOrders)
    }
}
