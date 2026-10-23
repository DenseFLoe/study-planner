import XCTest
@testable import StudyCore

final class SchedulePreferenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ offset: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: .init(year: 2026, month: 9, day: 14 + offset))!.addingTimeInterval(Double(minute * 60))
    }
    private func state(_ amounts: [Int], days: Int, whole: Bool = true) -> PlannerState {
        var state = PlannerState()
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        state.courses = amounts.enumerated().map { index, amount in
            var course = Course(name: "模拟课程\(index)", totalMinutes: amount, startDate: date(0), deadline: date(days - 1))
            course.id = stablePlannerID("preference-course-\(index)")
            if whole {
                course.type = .lessonBasedRecorded
                course.manualLessons = (0..<(amount / 60)).map { .init(id: "lesson\($0)", name: "模拟课节", durationMinutes: 60) }
            }
            return course
        }
        return state
    }
    private func order(_ rules: [ScheduleRule]) -> SchedulePriorities {
        .init(levels: Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($0.element.rawValue, $0.offset + 1) }))
    }
    private func plan(_ state: PlannerState) -> ScheduleResult {
        ScheduleEngine(calendar: calendar).generate(state: state, now: date(0, 480))
    }
    private func loads(_ result: ScheduleResult, days: Int) -> [Int] {
        (0..<days).map { d in result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(d)) }.reduce(0) { $0 + $1.durationMinutes } }
    }
    private func assertWorkPreserved(_ result: ScheduleResult, state: PlannerState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.risks.isEmpty, file: file, line: line)
        for course in state.courses {
            let work = result.tasks.filter { $0.courseID == course.id }
            XCTAssertEqual(work.reduce(0) { $0 + $1.durationMinutes }, state.remainingMinutes(for: course), file: file, line: line)
            if let lessons = course.manualLessons { XCTAssertEqual(work.map(\.lessonID), lessons.map { Optional($0.id) }, file: file, line: line) }
        }
        let helper = ScheduleEngineTests()
        helper.assertValid(result, state, now: date(0, 480), file: file, line: line)
    }

    func testWholeLessonsParticipateInDefaultDailyBalance() {
        let state = state([600], days: 5), result = plan(state)
        XCTAssertEqual(loads(result, days: 5), [120, 120, 120, 120, 120])
        assertWorkPreserved(result, state: state)
    }
    func testBalancedFirstBalancesTheCombinedDayInsteadOfEachCourseQuota() {
        var state = state([120, 120, 120], days: 3)
        state.settings.schedulePriorities = order([.balancedLoad, .diversity, .dailyWeight, .coursePriority])
        let result = plan(state)
        XCTAssertEqual(loads(result, days: 3), [120, 120, 120])
        assertWorkPreserved(result, state: state)
    }
    func testChangingBoostAndBalanceOrderChangesActualWholeLessonDates() {
        var state = state([240], days: 4)
        state.courses[0].dailyStudyWeight = 2
        state.settings.schedulePriorities = order([.dailyWeight, .balancedLoad, .diversity, .coursePriority])
        let boosted = plan(state)
        XCTAssertEqual(loads(boosted, days: 4), [120, 120, 0, 0])
        state.settings.schedulePriorities = order([.balancedLoad, .dailyWeight, .diversity, .coursePriority])
        let balanced = plan(state)
        XCTAssertEqual(loads(balanced, days: 4), [60, 60, 60, 60])
        assertWorkPreserved(boosted, state: state); assertWorkPreserved(balanced, state: state)
    }
    func testDefaultDiversityDoesNotCancelASingleCoursesBoost() {
        var state = state([240], days: 4)
        state.courses[0].dailyStudyWeight = 2
        let result = plan(state)
        XCTAssertEqual(loads(result, days: 4), [120, 120, 0, 0])
        assertWorkPreserved(result, state: state)
    }
    func testPriorityFirstAndDiversityFirstProduceDifferentWithinDayOrder() {
        var state = state([180, 180], days: 1)
        state.courses[0].priority = 3; state.courses[1].priority = 1
        state.settings.schedulePriorities = order([.coursePriority, .diversity, .dailyWeight, .balancedLoad])
        let prioritized = plan(state)
        XCTAssertEqual(prioritized.tasks.prefix(3).map(\.courseID), Array(repeating: state.courses[0].id, count: 3))
        state.settings.schedulePriorities = SchedulePriorities()
        let diverse = plan(state)
        for pair in zip(diverse.tasks, diverse.tasks.dropFirst()) { XCTAssertNotEqual(pair.0.courseID, pair.1.courseID) }
        assertWorkPreserved(prioritized, state: state); assertWorkPreserved(diverse, state: state)
    }
    func testFullDaysCanExchangeLessonsWithoutAnEmptyDestination() {
        let state = state([120, 120], days: 2)
        let days = (0..<2).map { SchedulePreferenceOptimizer.Day(date: date($0), windows: [.init(start: date($0, 480), end: date($0, 615))]) }
        let tasks = (0..<4).map { i in ScheduledTask(courseID: state.courses[i / 2].id, start: date(i / 2, 480 + i % 2 * 75), durationMinutes: 60,
                                                   lessonID: "lesson\(i % 2)") }
        let result = SchedulePreferenceOptimizer.optimize(tasks: tasks, courses: state.courses, days: days,
                                                         priorities: SchedulePriorities(), calendar: calendar)
        XCTAssertTrue(result.improved)
        for d in 0..<2 { XCTAssertEqual(Set(result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(d)) }.map(\.courseID)).count, 2) }
        XCTAssertEqual(result.tasks.count, tasks.count)
        for course in state.courses { XCTAssertEqual(result.tasks.filter { $0.courseID == course.id }.map(\.lessonID), ["lesson0", "lesson1"]) }
    }
    func testMixedDeadlinesKeepMandatoryWorkAndImproveOtherDays() {
        var state = state([480, 240, 240], days: 4)
        state.courses[0].deadline = date(0)
        let result = plan(state)
        XCTAssertEqual(result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(0)) }.map(\.courseID), Array(repeating: state.courses[0].id, count: 8))
        for d in 1..<4 { XCTAssertEqual(Set(result.tasks.filter { calendar.isDate($0.start, inSameDayAs: date(d)) }.map(\.courseID)).count, 2) }
        assertWorkPreserved(result, state: state)
    }
    func testEqualLevelsKeepDefaultOrderAndStableSchedule() {
        var state = state([240, 120, 120], days: 3)
        let original = plan(state)
        state.settings.schedulePriorities = .init(levels: Dictionary(uniqueKeysWithValues: ScheduleRule.allCases.map { ($0.rawValue, 1) }))
        XCTAssertEqual(plan(state).tasks, original.tasks)
        XCTAssertEqual(plan(state).tasks, plan(state).tasks)
    }
    func testEmptyAndUnbookedCoursesDoNotOverflowTargetCalculation() {
        var state = state([120, 60], days: 1)
        state.courses[1].minimumBlockMinutes = 60
        state.settings.availability = [.init(weekday: 2, startMinute: 480, endMinute: 540)]
        let result = plan(state)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.risks.last?.unscheduledMinutes, 120)
        state.settings.availability = []
        XCTAssertTrue(plan(state).tasks.isEmpty)
    }
    func testAndroidAndMacMatchAcrossEveryRulePermutation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("Android/build/tests/schedule-preference-parity.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Run ./Android/test.sh to generate synthetic preference parity fixtures") }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 24)
        for row in rows {
            let stateData = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["state"]))
            let state = try JSONDecoder().decode(PlannerState.self, from: stateData)
            let expectedData = try JSONSerialization.data(withJSONObject: XCTUnwrap(row["tasks"]))
            let expected = try JSONDecoder().decode([ScheduledTask].self, from: expectedData)
            let result = plan(state)
            XCTAssertEqual(result.tasks, expected, "Rule order: \(state.settings.schedulePriorities.orderedRules)")
            assertWorkPreserved(result, state: state)
        }
    }
}
