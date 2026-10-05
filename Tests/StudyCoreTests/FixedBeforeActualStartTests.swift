import XCTest
@testable import StudyCore

final class FixedBeforeActualStartTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int = 3, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day,
                                          hour: minute / 60, minute: minute % 60))!
    }
    private func fixture(minutes: Int, deadline: Int, end: Int) -> PlannerState {
        var state = PlannerState()
        state.courses = [.init(name: "数学", totalMinutes: minutes, startDate: date(), deadline: date(deadline))]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: end) }
        state.fixedEvents = [.init(title: "固定课", startMinute: 540, endMinute: 600,
                                   startDate: date(), endDate: date(4), weekdays: Set(1...7))]
        return state
    }

    func testStartBeforeInsideAtEndAndAfterFixedClass() throws {
        for (anchor, expected) in [(480, 480), (570, 600), (600, 600), (630, 630)] {
            var state = fixture(minutes: 120, deadline: 3, end: 1080)
            let events = state.fixedEvents
            _ = state.replan(now: date(3, 480), calendar: calendar)
            try state.recordActualStudyStart(minute: anchor, now: date(3, 840), calendar: calendar)
            let result = state.replan(now: date(3, 840), calendar: calendar)
            XCTAssertEqual(result.tasks.first?.start, date(3, expected), "anchor: \(anchor)")
            XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
            XCTAssertTrue(result.tasks.allSatisfy {
                $0.start >= date(3, anchor) && ($0.end <= date(3, 540) || $0.start >= date(3, 600))
            })
            XCTAssertTrue(result.risks.isEmpty)
            XCTAssertEqual(state.fixedEvents, events)
            XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 0)
            XCTAssertEqual(state.replan(now: date(3, 960), calendar: calendar).tasks, result.tasks)
            XCTAssertEqual(state.tasks, result.tasks)
        }
    }

    func testEarlierRecurringClassDoesNotConsumeTodayAgainOrDisappearTomorrow() throws {
        var state = fixture(minutes: 240, deadline: 4, end: 750)
        let events = state.fixedEvents
        try state.recordActualStudyStart(minute: 660, now: date(3, 840), calendar: calendar)
        let result = state.replan(now: date(3, 840), calendar: calendar)
        let today = result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date()) }
        let tomorrow = result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(4)) }
        XCTAssertEqual(today.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(tomorrow.reduce(0) { $0 + $1.durationMinutes }, 180)
        XCTAssertEqual(today.first?.start, date(3, 660))
        XCTAssertEqual(tomorrow.first?.start, date(4, 480))
        for task in result.tasks {
            let day = calendar.component(.day, from: task.start)
            XCTAssertTrue(task.end <= date(day, 540) || task.start >= date(day, 600))
        }
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(state.fixedEvents, events)
    }
}
