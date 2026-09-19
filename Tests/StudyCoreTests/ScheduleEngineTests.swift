import XCTest
@testable import StudyCore

final class ScheduleEngineTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }
    func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    func state(hours: Int = 10, deadline: Int = 18, start: Int = 14, unit: Int = 60) -> PlannerState {
        var s = PlannerState()
        s.courses = [.init(name: "数学", totalMinutes: hours * 60, startDate: date(start), deadline: date(deadline), minimumBlockMinutes: unit)]
        s.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 8 * 60, endMinute: 18 * 60) }
        return s
    }
    func result(_ s: PlannerState, now: Date? = nil) -> ScheduleResult {
        ScheduleEngine(calendar: cal).generate(state: s, now: now ?? date(14, 8))
    }
    func minutes(_ tasks: [ScheduledTask]) -> Int { tasks.reduce(0) { $0 + $1.durationMinutes } }
    func assertValid(_ r: ScheduleResult, _ s: PlannerState, now: Date? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let sorted = r.tasks.sorted { $0.start < $1.start }
        for (index, task) in sorted.enumerated() {
            XCTAssertGreaterThanOrEqual(task.start, now ?? date(14, 8), file: file, line: line)
            if index > 0 { XCTAssertLessThanOrEqual(sorted[index-1].end, task.start, file: file, line: line) }
            let course = s.courses.first { $0.id == task.courseID }!
            XCTAssertGreaterThanOrEqual(task.start, cal.startOfDay(for: course.startDate), file: file, line: line)
            XCTAssertLessThanOrEqual(task.end, cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: course.deadline))!, file: file, line: line)
            for event in s.fixedEvents where event.occurs(on: task.start, calendar: cal) {
                let engine = ScheduleEngine(calendar: cal)
                let start = engine.instant(day: task.start, minute: event.startMinute)
                let end = engine.instant(day: task.start, minute: event.endMinute)
                XCTAssertTrue(task.end <= start || task.start >= end, file: file, line: line)
            }
        }
        for course in s.courses {
            XCTAssertLessThanOrEqual(minutes(r.tasks.filter { $0.courseID == course.id }), s.remainingMinutes(for: course), file: file, line: line)
        }
    }
    func testEvenDistribution() {
        let s = state(); let r = result(s)
        XCTAssertTrue(r.risks.isEmpty); XCTAssertEqual(minutes(r.tasks), 600)
        for d in 14...18 { XCTAssertEqual(minutes(r.tasks.filter { cal.isDate($0.start, inSameDayAs: date(d)) }), 120) }
        XCTAssertEqual(r.demands[s.courses[0].id]?.averageMinutesPerDay, 120)
        assertValid(r, s)
    }
    func testFixedLessonsAndOverlappingFixedEventsAreMerged() {
        var s = state(hours: 6, deadline: 14)
        s.fixedEvents = [
            .init(title: "学校", startMinute: 480, endMinute: 600, startDate: date(14), endDate: date(14)),
            .init(title: "会议", startMinute: 540, endMinute: 630, startDate: date(14), endDate: date(14)),
            .init(title: "补习", startMinute: 840, endMinute: 960, startDate: date(14), endDate: date(14))]
        let r = result(s); assertValid(r,s)
        XCTAssertEqual(minutes(r.tasks), 300)
        XCTAssertEqual(r.risks.first?.unscheduledMinutes, 60)
    }
    func testMissedDayRedistributesWithoutAddingDebtTwice() throws {
        var s = state(); _ = s.replan(now: date(14, 8), calendar: cal)
        let yesterday = s.tasks.filter { cal.isDate($0.start, inSameDayAs: date(14)) }
        for t in yesterday { try s.confirm(taskID: t.id, actualMinutes: 0, now: date(15, 8)) }
        let r = s.replan(now: date(15, 8), calendar: cal)
        XCTAssertEqual(s.remainingMinutes(for: s.courses[0]), 600)
        XCTAssertEqual(minutes(r.tasks), 600)
        let daily = (15...18).map { d in minutes(r.tasks.filter { cal.isDate($0.start, inSameDayAs: date(d)) }) }
        XCTAssertEqual(daily.max()! - daily.min()!, 60)
        XCTAssertEqual(s.tasks.filter { $0.status == .missed }.count, yesterday.count)
        assertValid(r,s,now:date(15,8))
    }
    func testEarlyCompletionReleasesFutureTimeAndIsIdempotent() throws {
        var s = state(); _ = s.replan(now: date(14, 8), calendar: cal)
        let future = s.tasks.first { cal.isDate($0.start, inSameDayAs: date(16)) }!
        try s.confirm(taskID: future.id, actualMinutes: 60, now: date(14, 8))
        XCTAssertThrowsError(try s.confirm(taskID: future.id, actualMinutes: 60, now: date(14, 8)))
        let r = s.replan(now: date(14, 8), calendar: cal)
        XCTAssertEqual(s.completedMinutes(for: s.courses[0]), 60)
        XCTAssertEqual(minutes(r.tasks), 540)
        XCTAssertEqual(s.tasks.first { $0.id == future.id }?.status, .completed)
        assertValid(r,s)
    }
    func testFullCompletionRemovesOnlySelectedBlockAndUndoRestoresIt() throws {
        var s = state(); _ = s.replan(now: date(14, 8), calendar: cal)
        let original = s.tasks
        let selected = original[0]
        try s.confirm(taskID: selected.id, actualMinutes: selected.durationMinutes, now: date(14, 8))
        // The completion flow saves the existing schedule without immediately filling
        // the newly freed slot with a different block from the same course.
        XCTAssertEqual(s.tasks.filter(\.isUnconfirmed), original.filter { $0.id != selected.id })
        XCTAssertEqual(s.tasks.filter { !$0.isUnconfirmed }.map(\.id), [selected.id])
        let encoded = try JSONEncoder().encode(s)
        s = try JSONDecoder().decode(PlannerState.self, from: encoded)
        try s.undoConfirmation(taskID: selected.id, now: date(14, 8), calendar: cal)
        XCTAssertEqual(s.tasks, original)
        XCTAssertTrue(s.completions.isEmpty)
    }
    func testUndoConfirmationRestoresProgressAndCanBeReplanned() throws {
        var s = state(); _ = s.replan(now: date(14, 8), calendar: cal)
        let task = s.tasks.first { cal.isDate($0.start, inSameDayAs: date(16)) }!
        try s.confirm(taskID: task.id, actualMinutes: 30, now: date(14, 8))
        XCTAssertEqual(s.completedMinutes(for: s.courses[0]), 30)

        try s.undoConfirmation(taskID: task.id, now: date(14, 8), calendar: cal)

        XCTAssertEqual(s.completedMinutes(for: s.courses[0]), 0)
        XCTAssertFalse(s.completions.contains { $0.taskID == task.id })
        XCTAssertTrue(s.tasks.first { $0.id == task.id }!.isUnconfirmed)
        XCTAssertEqual(s.tasks.first { $0.id == task.id }?.completedMinutes, 0)
        XCTAssertThrowsError(try s.undoConfirmation(taskID: task.id, now: date(14, 8), calendar: cal))
        let r = s.replan(now: date(14, 8), calendar: cal)
        XCTAssertEqual(minutes(r.tasks), 600)
        assertValid(r, s)
    }
    func testPartialAndSubUnitFinalRemainder() throws {
        var s = state(hours: 2, deadline: 15); _ = s.replan(now:date(14,8), calendar:cal)
        let t = s.tasks[0]
        try s.confirm(taskID:t.id, actualMinutes:30, now:date(14,8))
        let r = s.replan(now:date(14,8),calendar:cal)
        XCTAssertEqual(minutes(r.tasks), 90)
        XCTAssertEqual(s.tasks.first { $0.id == t.id }?.status, .partial)
        XCTAssertTrue(r.tasks.contains { $0.durationMinutes == 30 })
    }
    func testPastAndActiveTasksRemainUnchanged() {
        var s = state(); _ = s.replan(now: date(14, 8), calendar: cal)
        let old = s.tasks.filter { $0.start < date(14, 8, 30) }
        let r = s.replan(now:date(14,8,30), calendar:cal)
        for t in old { XCTAssertEqual(s.tasks.first { $0.id == t.id }, t) }
        XCTAssertEqual(minutes(r.tasks), 600 - minutes(old))
        XCTAssertTrue(r.tasks.allSatisfy { $0.start >= old.last!.end })
        assertValid(r,s,now:date(14,8,30))
    }
    func testDeadlineCapacityWarningAcrossCourses() {
        var s = state(hours:8,deadline:14)
        s.courses.append(.init(name:"英语",totalMinutes:480,startDate:date(14),deadline:date(14)))
        let r = result(s)
        XCTAssertEqual(r.risks.count,1)
        XCTAssertEqual(r.risks[0].requiredMinutes,960)
        XCTAssertEqual(r.risks[0].availableMinutes,600)
        XCTAssertEqual(r.risks[0].capacityDeficit,360)
        XCTAssertEqual(r.risks[0].unscheduledMinutes,360)
        assertValid(r,s)
    }
    func testEarlierDeadlineWins() {
        var s = state(hours: 10, deadline: 15)
        let urgent = Course(name:"考试",totalMinutes:600,startDate:date(14),deadline:date(14))
        s.courses.append(urgent)
        let r = result(s)
        XCTAssertTrue(r.risks.isEmpty)
        XCTAssertEqual(minutes(r.tasks.filter { $0.courseID == urgent.id && cal.isDate($0.start,inSameDayAs:date(14)) }),600)
        assertValid(r,s)
    }
    func testWeeklyRecurrenceInclusiveSemesterBounds() {
        let e = FixedEvent(title:"课",startMinute:480,endMinute:600,startDate:date(14),endDate:date(21),weekdays:[2])
        XCTAssertTrue(e.occurs(on:date(14),calendar:cal)); XCTAssertTrue(e.occurs(on:date(21),calendar:cal))
        XCTAssertFalse(e.occurs(on:date(15),calendar:cal)); XCTAssertFalse(e.occurs(on:date(28),calendar:cal))
    }
    func testNonStudyDaysExcludedFromDailyDemand() {
        var s = state(hours:4,deadline:20)
        s.settings.availability = [.init(weekday:2,startMinute:480,endMinute:1080),.init(weekday:4,startMinute:480,endMinute:1080)]
        let r = result(s)
        XCTAssertEqual(r.demands[s.courses[0].id]?.learnableDays,2)
        XCTAssertEqual(r.demands[s.courses[0].id]?.averageMinutesPerDay,120)
        assertValid(r,s)
    }
    func testStartDateAndExpiredDeadline() {
        let delayed = state(hours:10,deadline:18,start:17)
        let r = result(delayed)
        XCTAssertTrue(r.tasks.allSatisfy { $0.start >= date(17) }); assertValid(r,delayed)
        let expired = result(state(hours:2,deadline:13))
        XCTAssertTrue(expired.tasks.isEmpty); XCTAssertEqual(expired.risks.first?.unscheduledMinutes,120)
    }
    func testFragmentedSlotsDoNotViolateMinimumUnit() {
        var s = state(hours:1,deadline:14)
        s.settings.availability = [.init(weekday:2,startMinute:480,endMinute:510),.init(weekday:2,startMinute:600,endMinute:630)]
        let r = result(s)
        XCTAssertTrue(r.tasks.isEmpty); XCTAssertEqual(r.risks.first?.unscheduledMinutes,60)
        XCTAssertEqual(r.risks.first?.capacityDeficit,0)
        s.courses[0].minimumBlockMinutes = 30
        XCTAssertEqual(minutes(result(s).tasks),60)
    }
    func testOverlappingAvailabilityIsNotDoubleCounted() {
        var s = state(hours:5,deadline:14)
        s.settings.availability = [.init(weekday:2,startMinute:480,endMinute:600),.init(weekday:2,startMinute:540,endMinute:660)]
        let r = result(s); XCTAssertEqual(minutes(r.tasks),180); assertValid(r,s)
    }
    func testDisabledAndCompletedCoursesGenerateNothing() {
        var s = state(); s.courses[0].autoScheduleEnabled = false
        XCTAssertTrue(result(s).tasks.isEmpty)
        s.courses[0].autoScheduleEnabled = true; s.courses[0].initialCompletedMinutes = 600
        XCTAssertTrue(result(s).tasks.isEmpty)
    }
    func testSettingsDeadlineAndDurationEditsTriggerNewPlan() {
        var s = state(); _ = s.replan(now:date(14,8),calendar:cal)
        s.courses[0].totalMinutes = 120; s.courses[0].deadline = date(14)
        s.settings.availability = [.init(weekday:2,startMinute:960,endMinute:1080)]
        let r = s.replan(now:date(14,8),calendar:cal)
        XCTAssertEqual(minutes(r.tasks),120); XCTAssertEqual(r.tasks.first?.start,date(14,16))
    }
    func testPersistenceRoundTrip() throws {
        var s = state(); _ = s.replan(now:date(14,8),calendar:cal)
        try s.confirm(taskID:s.tasks[0].id,actualMinutes:30,now:date(14,8))
        XCTAssertEqual(try JSONDecoder().decode(PlannerState.self,from:JSONEncoder().encode(s)),s)
    }
    func testMultipleCoursesInterleave() {
        var s = state(hours:4,deadline:15)
        s.courses.append(.init(name:"英语",totalMinutes:240,startDate:date(14),deadline:date(15)))
        let r = result(s)
        let today = r.tasks.filter { cal.isDate($0.start,inSameDayAs:date(14)) }
        XCTAssertEqual(Set(today.map(\.courseID)).count,2)
        XCTAssertGreaterThan(today.count,2)
        XCTAssertNotEqual(today[0].courseID,today[1].courseID)
        assertValid(r,s)
    }
    func testGeneratedScenariosPreserveConservationAndNoConflicts() {
        for seed in 1...40 {
            var s = state(hours:seed % 14 + 1, deadline:18, unit:seed % 2 == 0 ? 30 : 60)
            s.courses.append(.init(name:"英语",totalMinutes:(seed % 9 + 1) * 60,startDate:date(15),deadline:date(17),minimumBlockMinutes:30))
            s.fixedEvents = [.init(title:"午饭",startMinute:720,endMinute:780,startDate:date(14),endDate:date(18),weekdays:Set(1...7))]
            let r = result(s); assertValid(r,s)
            XCTAssertTrue(r.risks.isEmpty)
            XCTAssertEqual(minutes(r.tasks),s.courses.reduce(0) { $0 + s.remainingMinutes(for:$1) })
        }
    }
    func testMinuteCeilingNeverSchedulesInPast() {
        let s = state(hours:1,deadline:14)
        let now = date(14,8).addingTimeInterval(15)
        let r = result(s,now:now)
        XCTAssertEqual(r.tasks.first?.start,date(14,8,1)); assertValid(r,s,now:now)
    }
    func testNoAvailableTime() {
        var s = state(); s.settings.availability = []
        let r = result(s)
        XCTAssertTrue(r.tasks.isEmpty); XCTAssertEqual(r.risks.first?.unscheduledMinutes,600)
        XCTAssertEqual(r.demands[s.courses[0].id]?.learnableDays,0)
    }
    func testFragmentRepairMovesSmallBlockToFitLargeBlock() {
        var s = state(hours:1,deadline:14)
        s.settings.availability = [.init(weekday:2,startMinute:480,endMinute:570),.init(weekday:2,startMinute:660,endMinute:720)]
        s.courses.append(.init(name:"长课",totalMinutes:90,startDate:date(14),deadline:date(15),minimumBlockMinutes:90))
        let r = result(s)
        XCTAssertEqual(minutes(r.tasks),150); XCTAssertTrue(r.risks.isEmpty); assertValid(r,s)
    }
    func testLateStartCapacityWarningUsesEligibleDays() {
        let r = result(state(hours:20,deadline:18,start:18))
        XCTAssertEqual(r.risks.first?.availableMinutes,600)
        XCTAssertEqual(r.risks.first?.capacityDeficit,600)
    }
    func testFixedRuleEditsAndDeletionPreserveStartedOccurrence() throws {
        var s = state()
        let e = FixedEvent(title:"学校",startMinute:480,endMinute:600,startDate:date(7),endDate:date(28),weekdays:[2])
        s.fixedEvents = [e]
        var changed = e; changed.startMinute = 600; changed.endMinute = 660
        try s.updateFixedEvent(changed,now:date(14,9),calendar:cal)
        XCTAssertEqual(s.fixedEvents.count,2)
        XCTAssertEqual(s.fixedEvents.first { $0.occurs(on:date(14),calendar:cal) }?.startMinute,480)
        XCTAssertEqual(s.fixedEvents.first { $0.occurs(on:date(21),calendar:cal) }?.startMinute,600)
        s.removeFixedEvent(id:e.id,now:date(14,9),calendar:cal)
        XCTAssertTrue(s.fixedEvents.contains { $0.occurs(on:date(14),calendar:cal) && $0.startMinute == 480 })
    }
    func testFixedEventCannotCollideWithActiveTask() {
        var s = state(); _ = s.replan(now:date(14,8),calendar:cal)
        let event = FixedEvent(title:"会议",startMinute:480,endMinute:600,startDate:date(14),endDate:date(14))
        XCTAssertThrowsError(try s.updateFixedEvent(event,now:date(14,8,30),calendar:cal))
        XCTAssertTrue(s.fixedEvents.isEmpty)
    }
    func testArchivedCourseKeepsHistoryAndStopsFuturePlans() throws {
        var s = state(); _ = s.replan(now:date(14,8),calendar:cal)
        let past = s.tasks[0]
        try s.confirm(taskID:past.id,actualMinutes:60,now:date(14,9))
        s.courses[0].isArchived = true
        let r = s.replan(now:date(14,9),calendar:cal)
        XCTAssertTrue(r.tasks.isEmpty)
        XCTAssertEqual(s.tasks.first { $0.id == past.id }?.completedMinutes,60)
        XCTAssertEqual(s.completions.count,1)
    }
    func testDailyConfirmationAtEveningAndNextLaunch() throws {
        var s = state(); _ = s.replan(now:date(14,8),calendar:cal)
        XCTAssertTrue(s.confirmationCandidates(at:date(14,20),calendar:cal).isEmpty)
        let evening = s.confirmationCandidates(at:date(14,21),calendar:cal)
        XCTAssertEqual(evening.count,2)
        XCTAssertEqual(s.confirmationCandidates(at:date(15,7),calendar:cal),evening)
        try s.confirm(taskID:evening[0].id,actualMinutes:0,now:date(15,7))
        XCTAssertEqual(s.confirmationCandidates(at:date(15,7),calendar:cal).count,1)
    }
    func testOverlappingRecurringFixedEventsRejected() throws {
        var s = state()
        let first = FixedEvent(title:"课一",startMinute:480,endMinute:600,startDate:date(14),endDate:date(28),weekdays:[2])
        try s.updateFixedEvent(first,now:date(14,7),calendar:cal)
        let second = FixedEvent(title:"课二",startMinute:540,endMinute:660,startDate:date(14),endDate:date(28),weekdays:[2,4])
        XCTAssertThrowsError(try s.updateFixedEvent(second,now:date(14,7),calendar:cal))
        XCTAssertEqual(s.fixedEvents.count,1)
    }
    func testRecurringFixedEventReportsAllConflictsAndCanSkipDates() throws {
        var s = state()
        let first = FixedEvent(title:"已有课程",startMinute:480,endMinute:600,startDate:date(14),endDate:date(60),weekdays:[2])
        try s.updateFixedEvent(first,now:date(14,7),calendar:cal)
        let second = FixedEvent(title:"长期会议",startMinute:540,endMinute:660,startDate:date(14),endDate:date(60),weekdays:[2,3])
        var conflicts: [FixedEventConflict] = []
        do {
            try s.updateFixedEvent(second,now:date(14,7),calendar:cal)
            XCTFail("应报告重复星期内的所有冲突日期")
        } catch let PlannerError.fixedConflict(found) {
            conflicts = found
        }
        XCTAssertEqual(conflicts.count, 7)
        XCTAssertEqual(Set(conflicts.map(\.title)), ["已有课程"])
        let skipped = Set(conflicts.map(\.date))
        try s.updateFixedEvent(second,now:date(14,7),calendar:cal,skippingDates:skipped)
        XCTAssertEqual(s.fixedEvents.count, 2)
        let saved = s.fixedEvents[1]
        XCTAssertEqual(saved.excludedDates.count, skipped.count)
        XCTAssertFalse(saved.occurs(on: conflicts[0].date,calendar: cal))
        XCTAssertTrue(saved.occurs(on: date(15),calendar: cal))
    }
    func testLargeImpossibleWorkloadReturnsPromptly() {
        var s = state(hours:1000,deadline:30)
        s.fixedEvents = [.init(title:"午休",startMinute:720,endMinute:810,startDate:date(14),endDate:date(30),weekdays:Set(1...7))]
        let start = Date()
        let r = result(s)
        XCTAssertLessThan(Date().timeIntervalSince(start),3)
        XCTAssertFalse(r.risks.isEmpty)
        assertValid(r,s)
    }
}
