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
