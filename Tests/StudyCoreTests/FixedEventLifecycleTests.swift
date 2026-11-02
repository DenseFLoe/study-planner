import XCTest
@testable import StudyCore

extension ScheduleEngineTests {
    func testSingleFixedEventEndsAtItsOwnEndTime() {
        let event = FixedEvent(title: "单次课", startMinute: 480, endMinute: 600,
                               startDate: date(14), endDate: date(28))
        XCTAssertFalse(event.hasEnded(at: date(13, 23), calendar: cal))
        XCTAssertFalse(event.hasEnded(at: date(14, 9, 59), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(14, 10), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(15), calendar: cal))
    }

    func testRecurringFixedEventEndsAfterLastMatchingWeekday() {
        let event = FixedEvent(title: "每周一", startMinute: 480, endMinute: 600,
                               startDate: date(7), endDate: date(24), weekdays: [2])
        XCTAssertFalse(event.hasEnded(at: date(14, 10), calendar: cal))
        XCTAssertFalse(event.hasEnded(at: date(21, 9, 59), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(21, 10), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(24), calendar: cal))
    }

    func testFloatingFixedEventWaitsForWholeWindowAndMidnightBoundary() {
        var event = FixedEvent(title: "浮动事项", startMinute: 1200, endMinute: 1440,
                               startDate: date(14), endDate: date(14))
        event.floatingDurationMinutes = 30
        XCTAssertFalse(event.hasEnded(at: date(14, 20, 30), calendar: cal))
        XCTAssertFalse(event.hasEnded(at: date(14, 23, 59), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(15), calendar: cal))
    }

    func testTemporarySkipDoesNotPrematurelyCompleteRestorableRule() {
        let event = FixedEvent(title: "暂时跳过", startMinute: 480, endMinute: 600,
                               startDate: date(14), endDate: date(21), weekdays: [2],
                               excludedDates: [date(14), date(21)])
        XCTAssertFalse(event.hasEnded(at: date(14, 10), calendar: cal))
        XCTAssertFalse(event.hasEnded(at: date(21, 9), calendar: cal))
        XCTAssertTrue(event.hasEnded(at: date(21, 10), calendar: cal))
    }

    func testDeletingFixedRulesErasesPastStartedAndFutureOccurrencesOnlyForSelectedID() throws {
        for (start, end) in [(7, 7), (7, 28), (14, 14), (21, 28)] {
            var s = state(hours: 2)
            let event = FixedEvent(title: "要删除的课", startMinute: 480, endMinute: 600,
                                   startDate: date(start), endDate: date(end), weekdays: [2])
            var other = event; other.id = UUID()
            s.fixedEvents = [event, other]
            let task = ScheduledTask(courseID: s.courses[0].id, start: date(13, 8), durationMinutes: 60)
            s.tasks = [task]
            try s.confirm(taskID: task.id, actualMinutes: 60, now: date(13, 9))
            let original = s
            s.removeFixedEvent(id: event.id)
            XCTAssertEqual(s.fixedEvents, [other])
            XCTAssertEqual(s.tasks, original.tasks)
            XCTAssertEqual(s.completions, original.completions)
            XCTAssertEqual(s.courses, original.courses)
            s.removeFixedEvent(id: event.id)
            XCTAssertEqual(s.fixedEvents, [other])
        }
    }

    func testDeletingStartedFixedEventReleasesTodayForReplanning() {
        var s = state(hours: 1, deadline: 14)
        s.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 600)]
        let event = FixedEvent(title: "取消的固定课", startMinute: 480, endMinute: 600,
                               startDate: date(7), endDate: date(28), weekdays: [2])
        s.fixedEvents = [event]
        XCTAssertTrue(s.replan(now: date(14, 9), calendar: cal).tasks.isEmpty)
        s.removeFixedEvent(id: event.id)
        let after = s.replan(now: date(14, 9), calendar: cal)
        XCTAssertEqual(after.tasks.first?.start, date(14, 9))
        XCTAssertEqual(minutes(after.tasks), 60)
        XCTAssertTrue(after.risks.isEmpty)
        assertValid(after, s, now: date(14, 9))
    }
}
