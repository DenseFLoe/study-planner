import XCTest
@testable import StudyCore

final class ScheduleHealthTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int = 14, _ hour: Int = 8) -> Date {
        calendar.date(from: .init(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func state(_ minutes: [Int], end: Int = 13 * 60) -> PlannerState {
        var value = PlannerState()
        var course = Course(name: "模拟课程", totalMinutes: minutes.reduce(0,+), startDate: date(), deadline: date())
        course.type = .lessonBasedRecorded
        course.manualLessons = minutes.enumerated().map { .init(id: "lesson\($0.offset)", name: "第\($0.offset + 1)节", durationMinutes: $0.element) }
        value.courses = [course]
        value.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: end)]
        return value
    }
    private func assess(_ state: PlannerState, threshold: Int = 480) -> (ScheduleResult, ScheduleHealth) {
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: date())
        return (result, ScheduleHealthAnalyzer(calendar: calendar).assess(state: state, result: result, now: date(), heavyDayMinutes: threshold)!)
    }
    func testJointPlacementMovesFloatingEventInsteadOfReportingFalseShortage() {
        var value = state([120,90])
        var event = FixedEvent(title: "浮动事项", startMinute: 540, endMinute: 720, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 60
        value.fixedEvents = [event]
        let (result, health) = assess(value)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [120,90])
        XCTAssertEqual(result.tasks.map(\.lessonID), ["lesson0","lesson1"])
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertFalse(result.adjustments.isEmpty)
        XCTAssertEqual(health.status, .scheduled)
        XCTAssertEqual(result.tasks[1].start, date(14,11))
        XCTAssertEqual(value.courses[0].deadline, date())
    }
    func testHeavyButFeasibleIsDifferentFromShortageAndThresholdIsConfigurable() {
        let value = state([120,90])
        let (_, heavy) = assess(value, threshold: 180)
        XCTAssertEqual(heavy.status, .heavy)
        XCTAssertEqual(heavy.heavyDays, 1)
        XCTAssertEqual(heavy.peakMinutes, 210)
        XCTAssertEqual(assess(value, threshold: 240).1.status, .scheduled)
    }
    func testUnbookedAmountIsNotAProvenCapacityDeficit() {
        // Two separate windows have enough total minutes and each can hold a
        // lesson, but the five-minute external gap cannot supply a full break.
        // The conservative rest bound deliberately leaves this case unresolved.
        var value = state([60,60], end: 540)
        value.settings.availability.append(.init(weekday: 2, startMinute: 545, endMinute: 605))
        let (result, health) = assess(value)
        XCTAssertEqual(health.unscheduledMinutes, 60)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(health.status, .pending)
    }
    func testTrueMinuteShortageIncludesConservativeProof() {
        let (result, health) = assess(state([90,90], end: 600))
        XCTAssertEqual(health.status, .shortage)
        XCTAssertEqual(result.conflicts.first?.provenDeficit, 60)
    }
    func testTrueContinuousShortageDoesNotInventAMinuteDeficit() {
        var value = state([90], end: 540)
        value.settings.availability.append(.init(weekday: 2, startMinute: 600, endMinute: 660))
        let (result, health) = assess(value)
        XCTAssertEqual(health.status, .shortage)
        let proof = result.conflicts.first { $0.minimumContinuousMinutes != nil }
        XCTAssertEqual(proof?.minimumContinuousMinutes, 90)
        XCTAssertEqual(proof?.availableMinutes, 60)
        XCTAssertNil(proof?.provenDeficit)
    }
    func testFutureReleaseWindowCannotHideBehindEarlierFreeDays() {
        var value = state([180], end: 600)
        value.courses[0].startDate = date(15)
        value.courses[0].deadline = date(15)
        value.settings.availability.append(.init(weekday: 3, startMinute: 480, endMinute: 540))
        let (result, health) = assess(value)
        XCTAssertEqual(health.status, .shortage)
        XCTAssertTrue(result.conflicts.contains { $0.windowStart == date(15,0) && $0.provenDeficit == 120 })
    }
    func testPausedCourseRequiresAttentionWithoutClaimingImpossible() {
        var value = state([60])
        value.courses[0].autoScheduleEnabled = false
        let (_, health) = assess(value)
        XCTAssertEqual(health.status, .pending)
        XCTAssertEqual(health.pausedMinutes, 60)
        XCTAssertEqual(health.unscheduledMinutes, 0)
    }
    func testPartialCompletionCreditsOnlyActualMinutesAndLocatesRecovery() throws {
        var value = state([120,90])
        let first = value.replan(now: date(), calendar: calendar).tasks[0]
        let confirmation = date(14,9)
        try value.confirm(taskID: first.id, actualMinutes: 45, now: confirmation)
        let result = value.replan(now: confirmation, calendar: calendar)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer(calendar: calendar).assess(state: value, result: result, now: confirmation))
        XCTAssertEqual(value.remainingMinutes(for: value.courses[0]), 165)
        XCTAssertEqual(health.reviewedMinutes, 120)
        XCTAssertEqual(health.creditedMinutes, 45)
        XCTAssertEqual(health.recovery.reduce(0) { $0 + $1.plannedMinutes }, 75)
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 0)
        XCTAssertEqual(health.recoveryItems.map(\.minutes), [75])
        XCTAssertEqual(health.recoveryItems.first?.courseID, value.courses[0].id)
        XCTAssertEqual(health.recoveryItems.first?.lessonName, first.lessonName)
        XCTAssertThrowsError(try value.confirm(taskID: first.id, actualMinutes: 45, now: confirmation))
    }
    func testRepeatedMissedAttemptsNeverDoubleRecoveryDebt() throws {
        var value = state([60])
        for _ in 0..<2 {
            let task = value.replan(now: date(), calendar: calendar).tasks[0]
            try value.confirm(taskID: task.id, actualMinutes: 0, now: date())
        }
        let result = value.replan(now: date(), calendar: calendar)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer(calendar: calendar).assess(state: value, result: result, now: date()))
        XCTAssertEqual(health.recovery.reduce(0) { $0 + $1.plannedMinutes }, 60)
        XCTAssertEqual(health.reviewedMinutes - health.creditedMinutes, 120,
                       "Raw confirmation history must not be presented as remaining recovery work")
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 0)
        XCTAssertEqual(health.recoveryItems.reduce(0) { $0 + $1.minutes }, 60)
        XCTAssertEqual(value.remainingMinutes(for: value.courses[0]), 60)
    }
    func testLaterProgressReducesRecoveryToCurrentLessonRemainder() throws {
        var value = state([120])
        let first = value.replan(now: date(), calendar: calendar).tasks[0]
        try value.confirm(taskID: first.id, actualMinutes: 45, now: date(14,9))
        let second = value.replan(now: date(14,9), calendar: calendar).tasks[0]
        try value.confirm(taskID: second.id, actualMinutes: 30, now: date(14,10))
        let result = value.replan(now: date(14,10), calendar: calendar)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer(calendar: calendar).assess(state: value, result: result, now: date(14,10)))
        XCTAssertEqual(health.recovery.reduce(0) { $0 + $1.plannedMinutes }, 45)
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 0)
        XCTAssertEqual(health.recoveryItems.reduce(0) { $0 + $1.minutes }, 45)
    }
    func testRecoveryDistinguishesUnscheduledWorkFromNoWork() throws {
        var value = state([120])
        let first = value.replan(now: date(), calendar: calendar).tasks[0]
        try value.confirm(taskID: first.id, actualMinutes: 20, now: date(14,9))
        value.settings.availability = []
        let result = value.replan(now: date(14,9), calendar: calendar)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer(calendar: calendar).assess(state: value, result: result, now: date(14,9)))
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 100)
        XCTAssertTrue(health.recovery.isEmpty)
        XCTAssertTrue(health.recoveryItems.isEmpty)
    }
    func testPartialRecoveryAllocationReconcilesWithPerTaskDetails() throws {
        var value = state([60,60])
        let tasks = value.replan(now: date(), calendar: calendar).tasks
        for task in tasks { try value.confirm(taskID: task.id, actualMinutes: 0, now: date()) }
        value.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 540)]
        let (result, health) = assess(value)
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 60)
        XCTAssertEqual(health.recovery.reduce(0) { $0 + $1.plannedMinutes }, 60)
        for day in health.recovery {
            XCTAssertEqual(health.recoveryItems.filter { calendar.isDate($0.start, inSameDayAs: day.date) }
                .reduce(0) { $0 + $1.minutes }, day.plannedMinutes)
        }
        for item in health.recoveryItems {
            let task = try XCTUnwrap(result.tasks.first { $0.id == item.id })
            XCTAssertEqual(item.courseID, task.courseID)
            XCTAssertLessThanOrEqual(item.minutes, task.durationMinutes)
        }
    }
    func testRemovedLessonDoesNotBecomeUnscheduledRecovery() throws {
        var value = state([60,60])
        let first = value.replan(now: date(), calendar: calendar).tasks[0]
        try value.confirm(taskID: first.id, actualMinutes: 0, now: date())
        value.courses[0].manualLessons?.removeFirst()
        let (_, health) = assess(value)
        XCTAssertTrue(health.recovery.isEmpty)
        XCTAssertEqual(health.recoveryUnscheduledMinutes, 0)
        XCTAssertTrue(health.recoveryItems.isEmpty)
    }
    func testSearchBudgetExhaustionIsUnknownRatherThanAFalseProof() {
        let queue = ScheduleFeasibilitySearch.Queue(courseID: UUID(), start: 480, end: 780,
            work: [.init(minutes: 120, lessonID: "a", lessonName: "A"), .init(minutes: 90, lessonID: "b", lessonName: "B")])
        let windows = [ScheduleFeasibilitySearch.Window(start: 480, end: 780)]
        XCTAssertNil(ScheduleFeasibilitySearch.find(queues: [queue], study: windows, eventWindows: windows,
                                                   floating: [.init(key: date(), start: 540, end: 720, minutes: 60)],
                                                   floor: 480, initial: 0, expansionLimit: 0))
    }
}
