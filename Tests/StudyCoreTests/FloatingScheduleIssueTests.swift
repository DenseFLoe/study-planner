import XCTest
@testable import StudyCore

final class FloatingScheduleIssueTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func day(_ number: Int = 14, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: .init(year: 2026, month: 9, day: number))!
    }
    private func event(_ title: String, _ start: Int, _ end: Int, duration: Int? = nil) -> FixedEvent {
        var value = FixedEvent(title: title, startMinute: start, endMinute: end, startDate: day(), endDate: day())
        value.floatingDurationMinutes = duration
        return value
    }
    func testFragmentedWindowReportsActualContinuousLimitAndOnlyRelevantBlockers() throws {
        let floating = event("杂务", 480, 660, duration: 90)
        let meeting = event("会议", 540, 600)
        let unrelated = event("晚饭", 1080, 1140)
        var state = PlannerState()
        state.fixedEvents = [floating, meeting, unrelated]
        let original = state
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: day())
        let issue = try XCTUnwrap(result.floatingIssues.first)
        XCTAssertEqual(issue.date, day())
        XCTAssertEqual(issue.events.map(\.id), [floating.id, meeting.id])
        XCTAssertEqual(issue.reason, .continuousGap(required: 90, longest: 60))
        XCTAssertTrue(issue.isProvenConflict)
        XCTAssertTrue(issue.explanation.contains("最长连续空档只有 60 分钟"))
        XCTAssertTrue(issue.recovery.contains("跳过当次安排"))
        XCTAssertEqual(state, original)
    }
    func testOverlappingWindowsCountUnionCapacityOnce() throws {
        var state = PlannerState()
        state.fixedEvents = [event("A", 480, 600, duration: 90), event("B", 480, 600, duration: 90)]
        state.courses = [.init(name: "课程", totalMinutes: 60, startDate: day(), deadline: day())]
        state.settings.availability = [.init(weekday: 2, startMinute: 660, endMinute: 720)]
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: day())
        XCTAssertEqual(result.floatingIssues.first?.reason, .totalCapacity(required: 180, available: 120))
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertTrue(result.risks.isEmpty)
        let health = try XCTUnwrap(ScheduleHealthAnalyzer(calendar: calendar).assess(state: state, result: result, now: day()))
        XCTAssertEqual(health.status, .shortage, "A complete course plan must not hide impossible events")
    }
    func testNoSimpleProofDoesNotClaimThatAPlanIsImpossible() {
        let events = [event("A", 480, 600, duration: 60), event("B", 480, 600, duration: 60)]
        let issue = FloatingScheduleIssue.diagnose(events: events, on: day(), calendar: calendar)
        XCTAssertEqual(issue.reason, .unresolved)
        XCTAssertFalse(issue.isProvenConflict)
        XCTAssertTrue(issue.explanation.contains("尚不能据此断定时间不足"))
    }
    func testRecurringIssueDatesAndSkippingOneOccurrencePreserveTheRules() throws {
        var state = PlannerState()
        state.fixedEvents = [event("A", 480, 600, duration: 90), event("B", 480, 600, duration: 90)]
        for i in state.fixedEvents.indices {
            state.fixedEvents[i].endDate = day(16)
            state.fixedEvents[i].weekdays = [2, 3, 4]
        }
        state.courses = [.init(name: "课程", totalMinutes: 60, startDate: day(), deadline: day(16))]
        let engine = ScheduleEngine(calendar: calendar)
        XCTAssertEqual(engine.generate(state: state, now: day()).floatingIssues.map(\.date), [day(), day(15), day(16)])
        let id = state.fixedEvents[1].id, first = state.fixedEvents[0]
        try state.setFixedEventSkipped(id: id, on: day(15), skipped: true, now: day(), calendar: calendar)
        XCTAssertEqual(engine.generate(state: state, now: day()).floatingIssues.map(\.date), [day(), day(16)])
        XCTAssertEqual(state.fixedEvents[0], first)
        XCTAssertEqual(state.fixedEvents[1].excludedDates, [day(15)])
    }
    func testWindowRepairRemovesWarningWithoutDiscardingLearningOrOtherEvents() throws {
        var state = PlannerState()
        state.fixedEvents = [event("A", 480, 600, duration: 90), event("B", 480, 600, duration: 90)]
        state.courses = [.init(name: "课程", totalMinutes: 60, startDate: day(), deadline: day())]
        state.settings.availability = [.init(weekday: 2, startMinute: 720, endMinute: 780)]
        let first = state.fixedEvents[0]
        var repaired = state.fixedEvents[1]
        repaired.endMinute = 690
        try state.updateFixedEvent(repaired, now: day(), calendar: calendar)
        let result = ScheduleEngine(calendar: calendar).generate(state: state, now: day())
        XCTAssertTrue(result.floatingIssues.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(result.tasks.reduce(0) { $0 + $1.durationMinutes }, 60)
        XCTAssertEqual(state.fixedEvents[0], first)
        XCTAssertEqual(state.fixedEvents.count, 2)
    }
    func testClockGapUsesElapsedCapacityInsteadOfNominalClockMinutes() throws {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let date = cal.date(from: .init(year: 2026, month: 3, day: 8))!
        var state = PlannerState()
        var floating = event("DST", 60, 240, duration: 90)
        floating.startDate = date; floating.endDate = date
        var exact = event("固定", 180, 210)
        exact.startDate = date; exact.endDate = date
        state.fixedEvents = [floating, exact]
        let result = ScheduleEngine(calendar: cal).generate(state: state, now: date)
        XCTAssertEqual(result.floatingIssues.first?.reason, .continuousGap(required: 90, longest: 60))
    }
}
