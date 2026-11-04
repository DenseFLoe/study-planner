import XCTest
@testable import StudyCore

final class CalendarDaySnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return value
    }
    private var day: Date { calendar.date(from: .init(year: 2026, month: 11, day: 4))! }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = [.init(name: "Active", totalMinutes: 240, startDate: day, deadline: day + 86400)]
        state.tasks = [.init(courseID: state.courses[0].id, start: day + 36000, durationMinutes: 60)]
        return state
    }
    func testCalendarMarkersAndDayRowsUseTheSameArchiveVisibility() {
        var state = fixture(), archived = state.courses[0]
        archived.id = UUID(); archived.isArchived = true; state.courses.append(archived)
        let hidden = ScheduledTask(courseID: archived.id, start: day + 36000, durationMinutes: 60)
        var history = hidden; history.id = UUID(); history.status = .partial; history.completedMinutes = 20
        history.confirmedAt = day + 40000
        let orphan = ScheduledTask(courseID: UUID(), start: day, durationMinutes: 60)
        var orphanHistory = orphan; orphanHistory.id = UUID(); orphanHistory.status = .missed
        state.tasks += [hidden, history, orphan, orphanHistory]
        let original = state, snapshot = CalendarDaySnapshot(state: state, day: day, calendar: calendar)
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set([state.tasks[0].id, history.id, orphanHistory.id]))
        XCTAssertEqual(Set(CalendarDaySnapshot.visibleTasks(state.tasks, courses: state.courses).map(\.id)), Set(snapshot.tasks.map(\.id)))
        XCTAssertEqual(snapshot.plannedMinutes, 60)
        XCTAssertNil(snapshot.course(orphan.courseID)); XCTAssertEqual(snapshot.course(archived.id), archived)
        XCTAssertEqual(state, original)
    }
    func testTotalsFailExplicitlyWithoutLosingRowsOrTrapping() {
        var state = fixture(); state.tasks[0].durationMinutes = Int.max
        var second = state.tasks[0]; second.id = UUID(); second.durationMinutes = 1
        state.tasks.append(second)
        let overflow = CalendarDaySnapshot(state: state, day: day, calendar: calendar)
        XCTAssertNil(overflow.plannedMinutes); XCTAssertEqual(overflow.tasks.count, 2)
        state.tasks.removeLast()
        XCTAssertEqual(CalendarDaySnapshot(state: state, day: day, calendar: calendar).plannedMinutes, Int.max)
        state.tasks[0].durationMinutes = -1
        XCTAssertNil(CalendarDaySnapshot(state: state, day: day, calendar: calendar).plannedMinutes)
        XCTAssertEqual(CalendarDaySnapshot(state: PlannerState(), day: day, calendar: calendar).plannedMinutes, 0)
    }
    func testFloatingTotalsExcludeSkippedRulesAndStayChecked() {
        var state = fixture()
        var event = FixedEvent(title: "浮动", startMinute: 540, endMinute: 720, startDate: day, endDate: day)
        event.floatingDurationMinutes = 30
        var skipped = event; skipped.id = UUID(); skipped.excludedDates = [day + 60]
        state.fixedEvents = [skipped, event]
        let snapshot = CalendarDaySnapshot(state: state, day: day, calendar: calendar)
        XCTAssertEqual(snapshot.events, [event]); XCTAssertEqual(snapshot.skipped, [skipped])
        XCTAssertEqual(snapshot.floatingMinutes, 30)
        state.fixedEvents[0].excludedDates = []; state.fixedEvents[0].floatingDurationMinutes = Int.max
        XCTAssertNil(CalendarDaySnapshot(state: state, day: day, calendar: calendar).floatingMinutes)
    }
    func testLocalDayAndTieOrderingDoNotDependOnStorageOrder() {
        var state = fixture(), second = state.tasks[0]
        second.id = UUID(); state.tasks.append(second)
        var tomorrow = second; tomorrow.id = UUID(); tomorrow.start = day + 86400; state.tasks.append(tomorrow)
        let snapshot = CalendarDaySnapshot(state: state, day: day, calendar: calendar)
        XCTAssertEqual(snapshot.tasks.count, 2)
        state.tasks.reverse()
        XCTAssertEqual(CalendarDaySnapshot(state: state, day: day + 23 * 3600, calendar: calendar).tasks, snapshot.tasks)
        XCTAssertEqual(CalendarDaySnapshot(state: state, day: day + 86400, calendar: calendar).tasks, [tomorrow])
    }
    func testSnapshotRetainsItsOwnValuesWhenLiveStateChanges() {
        var state = fixture()
        let snapshot = CalendarDaySnapshot(state: state, day: day, calendar: calendar), id = state.courses[0].id
        state.courses[0].name = "Changed"; state.tasks[0].durationMinutes = 90
        XCTAssertEqual(snapshot.course(id)?.name, "Active")
        XCTAssertEqual(snapshot.tasks[0].durationMinutes, 60); XCTAssertEqual(snapshot.plannedMinutes, 60)
        XCTAssertEqual(CalendarDaySnapshot(state: state, day: day, calendar: calendar).plannedMinutes, 90)
    }
}
