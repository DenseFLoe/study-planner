import XCTest
@testable import StudyCore

final class ScheduleRestConflictTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ day: Int = 14, hour: Int = 8) -> Date {
        calendar.date(from: .init(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func fixture(_ minutes: [Int] = [60, 60], end: Int = 600) -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "休息约束课程", totalMinutes: minutes.reduce(0, +), startDate: date(), deadline: date())
        course.type = .lessonBasedRecorded
        course.manualLessons = minutes.enumerated().map {
            .init(id: "lesson\($0.offset)", name: "第\($0.offset + 1)节", durationMinutes: $0.element)
        }
        state.courses = [course]
        state.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: end)]
        return state
    }
    private func plan(_ state: PlannerState) -> ScheduleResult {
        ScheduleEngine(calendar: calendar).generate(state: state, now: date())
    }

    func testRestOnlyConflictExplainsWhyStudyMinutesAloneCannotFit() throws {
        let state = fixture(), before = state
        let result = plan(state)
        let conflict = try XCTUnwrap(result.conflicts.first)
        let rest = try XCTUnwrap(conflict.restConflict)
        XCTAssertEqual(rest.requiredStudyMinutes, 120)
        XCTAssertEqual(rest.minimumRestMinutes, 15)
        XCTAssertEqual(rest.availableMinutes, 120)
        XCTAssertNil(conflict.provenDeficit, "Rest is not missing learning progress")
        XCTAssertNil(conflict.minimumContinuousMinutes)
        XCTAssertEqual(result.risks.first?.unscheduledMinutes, 60)
        XCTAssertEqual(ScheduleHealthAnalyzer(calendar: calendar).assess(state: state, result: result, now: date())?.status, .shortage)
        XCTAssertTrue(rest.explanation.contains("15 分钟休息"))
        XCTAssertTrue(rest.recovery.contains("截止日期仍保留"))
        XCTAssertEqual(state, before)
    }

    func testAddingFifteenMinutesRecoversWithoutChangingLearningOrDeadline() {
        var state = fixture()
        let courses = state.courses
        XCTAssertNotNil(plan(state).conflicts.first?.restConflict)
        state.settings.availability[0].endMinute += 15
        let result = state.replan(now: date(), calendar: calendar)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60, 60])
        XCTAssertEqual(result.tasks[1].start.timeIntervalSince(result.tasks[0].end), 15 * 60)
        XCTAssertEqual(state.courses, courses)
        XCTAssertTrue(state.completions.isEmpty)
    }

    func testNoTrailingRestRequiredForSingleLessonOrExactlyFullPlan() {
        XCTAssertTrue(plan(fixture([120])).conflicts.isEmpty)
        XCTAssertTrue(plan(fixture([60, 60], end: 615)).conflicts.isEmpty)
    }

    func testRestBudgetCombinesCoursesAndOrdinaryTimeBlocks() throws {
        var state = fixture([60])
        var other = Course(name: "自主研习", totalMinutes: 60, startDate: date(), deadline: date())
        other.minimumBlockMinutes = 30
        state.courses.append(other)
        let conflict = try XCTUnwrap(plan(state).conflicts.first { $0.restConflict != nil })
        XCTAssertEqual(conflict.restConflict?.minimumRestMinutes, 30)
        XCTAssertEqual(Set(conflict.courseNames), Set(state.courses.map(\.name)))
    }

    func testFixedEventCanProvideRestWithoutDoubleCounting() {
        var state = fixture(end: 615)
        state.fixedEvents = [.init(title: "固定事项", startMinute: 540, endMinute: 555, startDate: date(), endDate: date())]
        let result = plan(state)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60, 60])
    }

    func testFloatingEventCanUseTheSameMinutesAsRest() {
        var state = fixture(end: 615)
        var event = FixedEvent(title: "浮动事项", startMinute: 540, endMinute: 555, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 15
        state.fixedEvents = [event]
        let result = plan(state)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
    }

    func testOvernightGapProvidesRestAndMovingAWindowCanRecover() {
        var state = fixture()
        state.courses[0].deadline = date(15)
        state.settings.availability[0].endMinute = 540
        state.settings.availability.append(.init(weekday: 3, startMinute: 480, endMinute: 540))
        let result = plan(state)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.map { calendar.component(.day, from: $0.start) }, [14, 15])
    }

    func testFutureCourseCannotUseEarlierDaysToHideItsRestConflict() throws {
        var state = fixture(end: 780)
        state.courses[0].startDate = date(15)
        state.courses[0].deadline = date(15)
        state.settings.availability.append(.init(weekday: 3, startMinute: 480, endMinute: 600))
        let conflict = try XCTUnwrap(plan(state).conflicts.first { $0.restConflict != nil })
        XCTAssertEqual(conflict.windowStart, date(15, hour: 0))
        XCTAssertEqual(conflict.restConflict?.availableMinutes, 120)
    }

    func testAdjacentOrOverlappingAvailabilityDoesNotCreateExtraRestExemptions() {
        for secondStart in [520, 540] {
            var state = fixture(end: 540)
            state.settings.availability.append(.init(weekday: 2, startMinute: secondStart, endMinute: 600))
            XCTAssertEqual(plan(state).conflicts.first?.restConflict?.minimumRestMinutes, 15)
        }
    }

    func testImmediateStudyDoesNotChargeThePinnedLessonRestTwice() throws {
        var state = fixture(end: 615)
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: calendar)
        let result = plan(state)
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 120)
    }

    func testCompletedHistoryDoesNotBecomeNewLearningOrNewBreaks() throws {
        var state = fixture(end: 615)
        let first = try XCTUnwrap(state.replan(now: date(), calendar: calendar).tasks.first)
        try state.confirm(taskID: first.id, actualMinutes: 60, now: date(hour: 9), calendar: calendar)
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: date(hour: 9))
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60])
    }

    func testSavedCompletePlanDoesNotInheritAnUnappliedDraftRestConflict() {
        var state = fixture(end: 615)
        _ = state.replan(now: date(), calendar: calendar)
        let engine = ScheduleEngine(calendar: calendar), now = date().addingTimeInterval(60)
        XCTAssertNotNil(engine.generate(state: state, now: now).conflicts.first?.restConflict)
        let saved = engine.assessSavedPlan(state: state, now: now)
        XCTAssertTrue(saved.conflicts.isEmpty)
        XCTAssertTrue(saved.risks.isEmpty)
        XCTAssertEqual(saved.tasks, state.tasks)
    }

    func testDaylightSavingUsesElapsedWindowMinutes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 3, day: 8, hour: 1)))
        var state = fixture()
        state.courses[0].startDate = now
        state.courses[0].deadline = now
        state.settings.availability = [.init(weekday: 1, startMinute: 60, endMinute: 240)]
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: now)
        XCTAssertEqual(result.conflicts.first?.restConflict?.availableMinutes, 120)
        XCTAssertEqual(result.conflicts.first?.restConflict?.minimumRestMinutes, 15)
    }

    func testDailyForecastCarriesRestReasonAndOldReportsStillDecode() throws {
        var state = fixture()
        state.courses[0].startDate = date(15)
        state.courses[0].deadline = date(15)
        state.settings.availability = [.init(weekday: 3, startMinute: 480, endMinute: 600)]
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let entry = try analyzer.capture(state: state, result: plan(state), now: date(), warningMinutes: 480)
        let forecast = try XCTUnwrap(analyzer.forecast(entry, fraction: 0, horizon: 1))
        let outcome = try XCTUnwrap(forecast.firstDay)
        XCTAssertEqual(outcome.kind, .shortage)
        XCTAssertEqual(outcome.restConflict?.minimumRestMinutes, 15)
        XCTAssertNil(outcome.provenDeficit)
        XCTAssertNil(outcome.continuousMinutes)
        let data = try JSONEncoder().encode(outcome)
        XCTAssertEqual(try JSONDecoder().decode(DailyConsequenceOutcome.self, from: data), outcome)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "restConflict")
        let restored = try JSONDecoder().decode(DailyConsequenceOutcome.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(restored.restConflict)
        XCTAssertEqual(restored.kind, outcome.kind)
    }

    func testRestBoundNeverRejectsSmallFeasibleSchedules() {
        // Enumerate block orders and window assignments independently of the
        // scheduler and bound. For each assignment, its earliest start dominates
        // later starts because there are no other release dates or appointments.
        func canPlace(_ blocks: [Int], in windows: [Range<Int>], after: Int = 0) -> Bool {
            if blocks.isEmpty { return true }
            for index in blocks.indices {
                var rest = blocks
                let length = rest.remove(at: index)
                for window in windows {
                    let start = max(after, window.lowerBound)
                    if start + length <= window.upperBound && canPlace(rest, in: windows, after: start + length + 15) {
                        return true
                    }
                }
            }
            return false
        }
        var proved = 0, feasible = 0, unresolved = 0
        for firstLength in [15, 30, 60] {
            for secondLength in [15, 30, 60] {
                for gap in [5, 15, 30] {
                    let windows = [0..<firstLength, (firstLength + gap)..<(firstLength + gap + secondLength)]
                    for first in [15, 30, 45] {
                        for second in [15, 30, 45] {
                            for third in [15, 30, 45] {
                                let possible = canPlace([first, second, third], in: windows)
                                let proof = ScheduleRestConflict.diagnose(studyMinutes: first + second + third, blockCount: 3,
                                    availableMinutes: firstLength + secondLength, windowCount: 2)
                                if possible { feasible += 1; XCTAssertNil(proof) }
                                if proof != nil { proved += 1; XCTAssertFalse(possible) }
                                if proof == nil && !possible { unresolved += 1 }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(feasible, 0)
        XCTAssertGreaterThan(proved, 0)
        XCTAssertGreaterThan(unresolved, 0)
        // One-window cases exercise the positive side of the proof.
        for length in 60...135 {
            let proof = ScheduleRestConflict.diagnose(studyMinutes: 120, blockCount: 2, availableMinutes: length, windowCount: 1)
            if proof != nil { proved += 1; XCTAssertLessThan(length, 135) }
            if length >= 135 { XCTAssertNil(proof) }
        }
        XCTAssertGreaterThan(proved, 0)
    }
}
