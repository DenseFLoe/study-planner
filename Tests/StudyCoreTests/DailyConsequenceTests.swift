import XCTest
@testable import StudyCore

final class DailyConsequenceTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }
    private func date(_ day: Int = 14, _ hour: Int = 8) -> Date {
        calendar.date(from: .init(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func fixture() -> (PlannerState, ScheduleResult, DailyConsequenceDay) {
        var state = PlannerState()
        var course = Course(name: "模拟课程", totalMinutes: 240, startDate: date(), deadline: date(16))
        course.type = .lessonBasedRecorded
        course.manualLessons = (0..<4).map { .init(id: "lesson\($0)", name: "第\($0)节", durationMinutes: 60) }
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 615) }
        let plan = state.replan(now: date(), calendar: calendar)
        let entry = DailyConsequenceAnalyzer(calendar: calendar).capture(state: state, result: plan, now: date(), warningMinutes: 120)
        return (state, plan, entry)
    }
    func testAllFiveOptionsArePresentAndPassingRequiresExceedingLowCompletionBand() {
        let (_, _, entry) = fixture()
        XCTAssertEqual(entry.goalMinutes, 120)
        XCTAssertEqual(entry.fractions, [0,250,500,750,1000])
        XCTAssertFalse(entry.achieved(250, confirmed: 30))
        XCTAssertTrue(entry.achieved(250, confirmed: 31))
        XCTAssertFalse(entry.achieved(0, confirmed: 0))
        XCTAssertTrue(entry.achieved(0, confirmed: 1))
        XCTAssertTrue(entry.achieved(1000, confirmed: 120))
        var tiny = entry; tiny.goalMinutes = 1
        XCTAssertEqual(tiny.fractions, [0,1000])
    }
    func testForecastDoesNotMutateCoursesOrRealProgress() throws {
        let (state, _, entry) = fixture()
        let before = state
        let value = try XCTUnwrap(DailyConsequenceAnalyzer(calendar: calendar).forecast(entry, fraction: 0, horizon: 10))
        XCTAssertEqual(state, before)
        XCTAssertEqual(value.firstDay?.kind, .scheduled)
        XCTAssertEqual(value.provenLimitAfterDays, 2)
        XCTAssertNil(value.uncertainFromDay)
        XCTAssertEqual(state.courses[0].deadline, date(16))
    }
    func testFullDailyCompletionDoesNotInventDebtOrHardLimit() throws {
        let (_, _, entry) = fixture()
        let value = try XCTUnwrap(DailyConsequenceAnalyzer(calendar: calendar).forecast(entry, fraction: 1000, horizon: 10))
        XCTAssertNil(value.provenLimitAfterDays)
        XCTAssertEqual(value.firstDay?.kind, .scheduled)
    }
    func testConfirmedProgressDoesNotMoveTheCapturedDailyGoal() throws {
        var (state, plan, entry) = fixture()
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        try state.confirm(taskID: plan.tasks[0].id, actualMinutes: 31, now: date(14,9), calendar: calendar)
        plan = state.replan(now: date(14,9), calendar: calendar)
        XCTAssertEqual(entry.goalMinutes, 120)
        XCTAssertEqual(analyzer.confirmed(on: entry.date, state: state), 31)
        XCTAssertEqual(analyzer.revision(state: state, warningMinutes: 120), entry.revision)
        XCTAssertTrue(analyzer.capturedEvidenceIsValid(entry, state: state))
        XCTAssertTrue(entry.achieved(250, confirmed: 31))
    }
    func testExternalProgressRefreshInvalidatesForecastWithoutChangingPhysicalConfiguration() {
        var (state, _, entry) = fixture()
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        state.courses[0].initialCompletedMinutes = 20
        XCTAssertEqual(analyzer.revision(state: state, warningMinutes: 120), entry.revision)
        XCTAssertFalse(analyzer.capturedEvidenceIsValid(entry, state: state))
    }
    func testBackfilledPastStudyRefreshesTodayWithoutCountingAsTodaysAchievement() throws {
        var (state, plan, entry) = fixture()
        try state.confirm(taskID: plan.tasks[0].id, actualMinutes: 30, now: date(), studyDate: date(13), calendar: calendar)
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        XCTAssertEqual(analyzer.confirmed(on: date(), state: state), 0)
        XCTAssertFalse(analyzer.capturedEvidenceIsValid(entry, state: state))
        XCTAssertEqual(analyzer.revision(state: state, warningMinutes: 120), entry.revision)
    }
    func testDatedOrphanCompletionIsAppliedToRemainingWorkWithoutInventingAConflict() {
        var (state, _, _) = fixture()
        state.courses[0].deadline = date(15)
        let result = state.replan(now: date(), calendar: calendar)
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let entry = analyzer.capture(state: state, result: result, now: date(), warningMinutes: 120)
        state.completions.append(.init(courseID: state.courses[0].id, taskID: UUID(), minutes: 120, recordedAt: date(15), studyDate: date()))
        XCTAssertEqual(analyzer.reality(entry, state: state).outcome?.kind, .scheduled)
    }
    func testNextDayBackfillIsAssignedToActualStudyDay() throws {
        var (state, _, entry) = fixture()
        for (index, task) in entry.plannedToday.enumerated() {
            try state.confirm(taskID: task.id, actualMinutes: index == 0 ? 30 : 0, now: date(15), studyDate: date(), calendar: calendar)
        }
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let reality = analyzer.reality(entry, state: state)
        XCTAssertEqual(reality.confirmedMinutes, 30)
        XCTAssertEqual(analyzer.confirmed(on: date(15), state: state), 0)
        XCTAssertTrue(reality.isReviewed)
        XCTAssertNotNil(reality.outcome)
    }
    func testUnconfirmedDayIsNotDeclaredZeroStudyOrReviewed() {
        let (state, _, entry) = fixture()
        let value = DailyConsequenceAnalyzer(calendar: calendar).reality(entry, state: state)
        XCTAssertEqual(value.confirmedMinutes, 0)
        XCTAssertFalse(value.isReviewed)
        XCTAssertTrue(value.achievedFractions.isEmpty)
    }
    func testAmbiguousLegacyBackfillDoesNotBecomeTodayOrYesterdayActual() throws {
        var (state, _, entry) = fixture()
        let task = entry.plannedToday[0]
        try state.confirm(taskID: task.id, actualMinutes: 30, now: date(15), calendar: calendar)
        state.completions[0].studyDate = nil
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        XCTAssertNil(analyzer.effectiveDay(state.completions[0], state: state))
        let reality = analyzer.reality(entry, state: state)
        XCTAssertEqual(reality.ambiguousRecords, 1)
        XCTAssertFalse(reality.isReviewed)
    }
    func testUndoingCapturedProgressInvalidatesItsAssumptions() throws {
        var (state, plan, _) = fixture()
        let task = plan.tasks[0]
        try state.confirm(taskID: task.id, actualMinutes: 30, now: date(), calendar: calendar)
        plan = state.replan(now: date(), calendar: calendar)
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let captured = analyzer.capture(state: state, result: plan, now: date(), warningMinutes: 120)
        try state.undoConfirmation(taskID: task.id, now: date(), calendar: calendar)
        XCTAssertFalse(analyzer.capturedEvidenceIsValid(captured, state: state))
    }
    func testStudyDateIsOptionalForOldDataAndPreservedForNewData() throws {
        var (state, plan, _) = fixture()
        try state.confirm(taskID: plan.tasks[0].id, actualMinutes: 30, now: date(15), studyDate: date(), calendar: calendar)
        let data = try JSONEncoder().encode(state.completions[0])
        XCTAssertEqual(try JSONDecoder().decode(CompletionRecord.self, from: data).studyDate, date(14,0))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "studyDate")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(CompletionRecord.self, from: old).studyDate)
        let before = state
        XCTAssertThrowsError(try state.confirm(taskID: plan.tasks[1].id, actualMinutes: 1, now: date(15), studyDate: date(16), calendar: calendar))
        XCTAssertEqual(state, before)
    }
    func testRevisionSurvivesPersistenceAndUnorderedConfigurationCollections() throws {
        var (state, _, _) = fixture()
        var event = FixedEvent(title: "模拟事项", startMinute: 800, endMinute: 830, startDate: date(), endDate: date(20), weekdays: [2,3,5])
        event.excludedDates = [date(16),date(18)]
        state.fixedEvents = [event]
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let original = analyzer.revision(state: state, warningMinutes: 120)
        var decoded = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        decoded.settings.availability.reverse()
        decoded.fixedEvents[0].weekdays = Set([5,3,2])
        XCTAssertEqual(analyzer.revision(state: decoded, warningMinutes: 120), original)
    }
}
