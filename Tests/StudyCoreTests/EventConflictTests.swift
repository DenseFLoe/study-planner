import XCTest
@testable import StudyCore

extension ScheduleEngineTests {
    func testConflictDetailsAndIndependentDateSkippingAreAtomic() throws {
        var s = PlannerState()
        let first = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(16), weekdays: [2, 3, 4])
        let second = FixedEvent(title: "会议", startMinute: 610, endMinute: 630, startDate: date(14), endDate: date(14))
        s.fixedEvents = [first, second]
        let requested = FixedEvent(title: "新事项", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(17), weekdays: [2, 3, 4, 5])
        let original = s
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal)
            XCTFail("Expected detailed conflicts")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(conflicts.count, 4)
            XCTAssertEqual(Set(conflicts.map(\.date)).count, 3)
            XCTAssertEqual(conflicts[0].title, "学校")
            XCTAssertEqual(conflicts[0].timeDescription, "08:00–10:00")
            XCTAssertEqual(conflicts[0].explanation, "重叠 09:00–10:00（60 分钟）")
            XCTAssertTrue(PlannerError.fixedConflict(conflicts).localizedDescription.contains("会议"))
        }
        XCTAssertEqual(s, original)
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingDates: [date(14, 12)])
            XCTFail("Unselected dates must still block save")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(Set(conflicts.map(\.date)), [date(15), date(16)])
        }
        XCTAssertEqual(s, original)
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingDates: [date(14), date(15), date(16)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        XCTAssertTrue(saved.occurs(on: date(17), calendar: cal))
        XCTAssertFalse(saved.occurs(on: date(14), calendar: cal))
        XCTAssertEqual(s.fixedEvents[0], first)
    }

    func testNewEventCanMoveUnconfirmedLearningToday() throws {
        var s = state(hours: 1, deadline: 14)
        s.tasks = [.init(courseID: s.courses[0].id, start: date(14, 8), durationMinutes: 60)]
        let requested = FixedEvent(title: "会议", startMinute: 510, endMinute: 570, startDate: date(14), endDate: date(14))
        try s.updateFixedEvent(requested, now: date(14, 8, 15), calendar: cal)
        let r = s.replan(now: date(14, 8, 15), calendar: cal)
        XCTAssertEqual(s.fixedEvents.count, 1)
        XCTAssertEqual(r.tasks.first?.start, date(14, 9, 30))
        XCTAssertEqual(s.tasks.count, 1)
        assertValid(r, s, now: date(14, 8, 15))
    }

    func testSingleOccurrenceConflictCanBeExplicitlySkipped() throws {
        var s = PlannerState()
        let old = FixedEvent(title: "已有", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(14))
        s.fixedEvents = [old]
        let requested = FixedEvent(title: "单次", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(14))
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingDates: [date(14)])
        XCTAssertFalse(s.fixedEvents[1].occurs(on: date(14), calendar: cal))
        XCTAssertEqual(s.fixedEvents[0], old)
    }

    func testFloatingCapacityConflictIncludesWindowsAndDuration() throws {
        var s = PlannerState()
        var old = FixedEvent(title: "浮动杂务", startMinute: 840, endMinute: 960, startDate: date(14), endDate: date(14))
        old.floatingDurationMinutes = 90
        s.fixedEvents = [old]
        var requested = old
        requested.id = UUID()
        requested.title = "另一项"
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal)
            XCTFail("Expected capacity conflict")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(conflicts.first?.reason, .floatingCapacity)
            XCTAssertEqual(conflicts.first?.timeDescription, "14:00–16:00 · 浮动占用 90 分钟")
            XCTAssertEqual(conflicts.first?.requestedStartMinute, 840)
        }
    }
}
