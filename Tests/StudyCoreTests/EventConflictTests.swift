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

    /// Selecting local dates clears every local item that blocks the new rule,
    /// while items on the same day without an overlap and items on other days stay intact.
    func testSkippingExistingDatesClearsAllLocalConflictsAndKeepsUnrelatedItems() throws {
        var s = PlannerState()
        let school = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(13), endDate: date(16), weekdays: [1, 2, 3, 4])
        let meeting = FixedEvent(title: "会议", startMinute: 610, endMinute: 630, startDate: date(14), endDate: date(14))
        let lunch = FixedEvent(title: "午饭", startMinute: 720, endMinute: 780, startDate: date(14), endDate: date(14))
        let gym = FixedEvent(title: "健身", startMinute: 480, endMinute: 600, startDate: date(18), endDate: date(18))
        s.fixedEvents = [school, meeting, lunch, gym]
        let requested = FixedEvent(title: "新事项", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(17), weekdays: [2, 3, 4, 5])
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal)
            XCTFail("Expected every local conflict to block the save")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(conflicts.count, 4)
            XCTAssertEqual(Set(conflicts.map(\.title)), ["学校", "会议"])
        }
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal,
                               skippingExistingDates: [date(14), date(15), date(16)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        for day in [14, 15, 16, 17] {
            XCTAssertTrue(saved.occurs(on: date(day), calendar: cal), "新事项不应被排除：\(day) 日")
        }
        let keptSchool = try XCTUnwrap(s.fixedEvents.first { $0.id == school.id })
        XCTAssertEqual(keptSchool.excludedDates, Set([date(14), date(15), date(16)]))
        XCTAssertEqual(keptSchool.title, school.title)
        XCTAssertEqual(keptSchool.startMinute, school.startMinute)
        XCTAssertEqual(keptSchool.endMinute, school.endMinute)
        XCTAssertEqual(keptSchool.startDate, school.startDate)
        XCTAssertEqual(keptSchool.endDate, school.endDate)
        XCTAssertEqual(keptSchool.weekdays, school.weekdays)
        XCTAssertTrue(keptSchool.occurs(on: date(13), calendar: cal))
        let keptMeeting = try XCTUnwrap(s.fixedEvents.first { $0.id == meeting.id })
        XCTAssertEqual(keptMeeting.excludedDates, Set([date(14)]))
        // A local item on a selected day without an overlap, and an item on an
        // unrelated day, must keep their dates and rules unchanged.
        XCTAssertEqual(try XCTUnwrap(s.fixedEvents.first { $0.id == lunch.id }), lunch)
        XCTAssertEqual(try XCTUnwrap(s.fixedEvents.first { $0.id == gym.id }), gym)
        XCTAssertEqual(s.fixedEvents.count, 5)
    }

    /// Each day picks its own policy: 14 and 16 cancel the local item, 15 cancels the new one.
    func testMixedDatePoliciesSkipIncomingAndLocalPerDay() throws {
        var s = PlannerState()
        let school = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(16), weekdays: [2, 3, 4])
        let meeting = FixedEvent(title: "会议", startMinute: 610, endMinute: 630, startDate: date(15), endDate: date(15))
        s.fixedEvents = [school, meeting]
        let requested = FixedEvent(title: "新事项", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(16), weekdays: [2, 3, 4])
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal,
                               skippingDates: [date(15)],
                               skippingExistingDates: [date(14), date(16)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        XCTAssertTrue(saved.occurs(on: date(14), calendar: cal))
        XCTAssertFalse(saved.occurs(on: date(15), calendar: cal))
        XCTAssertTrue(saved.occurs(on: date(16), calendar: cal))
        let keptSchool = try XCTUnwrap(s.fixedEvents.first { $0.id == school.id })
        XCTAssertEqual(keptSchool.excludedDates, Set([date(14), date(16)]))
        XCTAssertFalse(keptSchool.occurs(on: date(14), calendar: cal))
        XCTAssertTrue(keptSchool.occurs(on: date(15), calendar: cal))
        XCTAssertFalse(keptSchool.occurs(on: date(16), calendar: cal))
        // Skipping the incoming item on 15 must leave the local item on 15 untouched.
        XCTAssertEqual(try XCTUnwrap(s.fixedEvents.first { $0.id == meeting.id }), meeting)
        XCTAssertTrue(meeting.occurs(on: date(15), calendar: cal))
    }

    /// Unhandled conflicts and validation failures must not leave partial local cancellations.
    func testUnresolvedConflictOrInvalidEditLeavesStateUntouched() throws {
        var s = PlannerState()
        let school = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(15), weekdays: [2, 3])
        s.fixedEvents = [school]
        let requested = FixedEvent(title: "新事项", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(15), weekdays: [2, 3])
        let original = s
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingExistingDates: [date(14)])
            XCTFail("The unselected local date must still block the save")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(conflicts.map(\.date), [date(15)])
        }
        XCTAssertEqual(s, original)
        XCTAssertTrue(s.fixedEvents.first?.excludedDates.isEmpty ?? false)
        var invalid = requested
        invalid.endMinute = invalid.startMinute
        do {
            try s.updateFixedEvent(invalid, now: date(14, 7), calendar: cal, skippingExistingDates: [date(14)])
            XCTFail("An invalid edit must be rejected")
        } catch PlannerError.invalidFixedEvent {}
        XCTAssertEqual(s, original)
        XCTAssertTrue(s.fixedEvents.first?.excludedDates.isEmpty ?? false)
    }

    /// A floating capacity conflict is resolvable by cancelling only the local floating item.
    func testFloatingCapacityConflictCanSkipOnlyTheLocalItem() throws {
        var s = PlannerState()
        var local = FixedEvent(title: "浮动杂务", startMinute: 840, endMinute: 960, startDate: date(14), endDate: date(14))
        local.floatingDurationMinutes = 90
        s.fixedEvents = [local]
        var requested = local
        requested.id = UUID()
        requested.title = "另一项"
        do {
            try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal)
            XCTFail("Expected a capacity conflict")
        } catch let PlannerError.fixedConflict(conflicts) {
            XCTAssertEqual(conflicts.first?.reason, .floatingCapacity)
        }
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingExistingDates: [date(14)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        XCTAssertTrue(saved.occurs(on: date(14), calendar: cal))
        let kept = try XCTUnwrap(s.fixedEvents.first { $0.id == local.id })
        XCTAssertEqual(kept.excludedDates, Set([date(14)]))
        XCTAssertFalse(kept.occurs(on: date(14), calendar: cal))
        XCTAssertEqual(kept.floatingDurationMinutes, 90)
        XCTAssertEqual(kept.startMinute, 840)
        XCTAssertEqual(kept.endMinute, 960)
        XCTAssertEqual(s.fixedEvents.count, 2)
    }

    /// Cancelling one occurrence keeps the local rule's past dates, later dates and bounds.
    func testSkippingExistingKeepsLocalHistoryAndRecurringRule() throws {
        var s = PlannerState()
        let school = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(13), endDate: date(16), weekdays: [1, 2, 3, 4])
        s.fixedEvents = [school]
        let requested = FixedEvent(title: "补课", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(14))
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal, skippingExistingDates: [date(14)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        XCTAssertTrue(saved.occurs(on: date(14), calendar: cal))
        let kept = try XCTUnwrap(s.fixedEvents.first { $0.id == school.id })
        XCTAssertEqual(kept.id, school.id)
        XCTAssertEqual(kept.startDate, school.startDate)
        XCTAssertEqual(kept.endDate, school.endDate)
        XCTAssertEqual(kept.weekdays, school.weekdays)
        XCTAssertTrue(kept.occurs(on: date(13), calendar: cal), "历史日期必须保留")
        XCTAssertFalse(kept.occurs(on: date(14), calendar: cal))
        XCTAssertTrue(kept.occurs(on: date(15), calendar: cal), "其余重复日期必须保留")
        XCTAssertTrue(kept.occurs(on: date(16), calendar: cal))
        XCTAssertEqual(s.fixedEvents.count, 2)
    }

    /// When both sets contain the same day, the incoming item is skipped and local items stay.
    func testOverlappingSelectionsPreferSkippingTheNewEvent() throws {
        var s = PlannerState()
        let school = FixedEvent(title: "学校", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(14))
        s.fixedEvents = [school]
        let requested = FixedEvent(title: "新事项", startMinute: 540, endMinute: 660, startDate: date(14), endDate: date(14))
        try s.updateFixedEvent(requested, now: date(14, 7), calendar: cal,
                               skippingDates: [date(14)], skippingExistingDates: [date(14)])
        let saved = try XCTUnwrap(s.fixedEvents.first { $0.id == requested.id })
        XCTAssertFalse(saved.occurs(on: date(14), calendar: cal))
        let kept = try XCTUnwrap(s.fixedEvents.first { $0.id == school.id })
        XCTAssertEqual(kept, school)
        XCTAssertTrue(kept.occurs(on: date(14), calendar: cal))
        XCTAssertEqual(s.fixedEvents.count, 2)
    }
}
