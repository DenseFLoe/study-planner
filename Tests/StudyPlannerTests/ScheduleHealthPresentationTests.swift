import XCTest
@testable import StudyCore
@testable import StudyPlanner

final class ScheduleHealthPresentationTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_794_355_200)

    func testCourseBreakdownDoesNotSumCumulativeDeadlineRisksOrMatchNames() {
        var state = PlannerState()
        let first = Course(name: "同名课程", totalMinutes: 180, startDate: day, deadline: day)
        let second = Course(name: "同名课程", totalMinutes: 300, startDate: day, deadline: day.addingTimeInterval(86400))
        state.courses = [first, second]
        let result = ScheduleResult(tasks: [
            .init(courseID: first.id, start: day, durationMinutes: 120),
            .init(courseID: second.id, start: day, durationMinutes: 120)
        ], risks: [
            .init(deadline: first.deadline, requiredMinutes: 180, availableMinutes: 120, unscheduledMinutes: 60, courseNames: [first.name]),
            .init(deadline: second.deadline, requiredMinutes: 480, availableMinutes: 240, unscheduledMinutes: 240, courseNames: [first.name, second.name])
        ], demands: [:], diagnostics: [])

        let rows = CourseScheduleAttention.items(state: state, result: result)
        XCTAssertEqual(rows.map(\.id), [first.id, second.id])
        XCTAssertEqual(rows.map(\.unplacedMinutes), [60, 180])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.unplacedMinutes }, 240)
        XCTAssertEqual(rows.map(\.plannedMinutes), [120, 120])
    }

    func testPausedAndArchivedCoursesDoNotMisrepresentUnplacedWork() {
        var state = PlannerState()
        var paused = Course(name: "暂停课程", totalMinutes: 120, startDate: day, deadline: day)
        paused.autoScheduleEnabled = false
        var archived = Course(name: "归档课程", totalMinutes: 180, startDate: day, deadline: day)
        archived.isArchived = true
        let scheduled = Course(name: "已安排课程", totalMinutes: 60, startDate: day, deadline: day)
        state.courses = [paused, archived, scheduled]
        let result = ScheduleResult(tasks: [.init(courseID: scheduled.id, start: day, durationMinutes: 60)],
                                    risks: [], demands: [:], diagnostics: [])
        let rows = CourseScheduleAttention.items(state: state, result: result)
        XCTAssertEqual(rows.map(\.id), [paused.id])
        XCTAssertEqual(rows.first?.plannedMinutes, 0)
        XCTAssertEqual(rows.first?.unplacedMinutes, 120)
    }

    func testCourseBreakdownUsesRemainingWorkAfterCompletion() {
        var state = PlannerState()
        let course = Course(name: "课程", totalMinutes: 180, startDate: day, deadline: day)
        state.courses = [course]
        state.completions = [.init(courseID: course.id, taskID: UUID(), minutes: 60, recordedAt: day)]
        let result = ScheduleResult(tasks: [.init(courseID: course.id, start: day, durationMinutes: 90)],
                                    risks: [], demands: [:], diagnostics: [])
        let row = CourseScheduleAttention.items(state: state, result: result).first
        XCTAssertEqual(row?.remainingMinutes, 120)
        XCTAssertEqual(row?.unplacedMinutes, 30)
    }

    func testOverviewSeparatesPausedWorkFromActiveUnscheduledWork() {
        var health = health()
        health.remainingMinutes = 600
        health.unscheduledMinutes = 120
        health.pausedMinutes = 60
        let presentation = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertTrue(presentation.overview.contains("已安排 7 小时"))
        XCTAssertTrue(presentation.overview.contains("还有 2 小时未排入日程"))
        XCTAssertTrue(presentation.overview.contains("另有 1 小时因课程暂停"))
        XCTAssertTrue(presentation.guidance.contains("并不代表一定来不及学完"))
    }

    func testHeavyDayFilterUsesStrictThresholdAndSameMinimumAsAnalyzer() {
        var health = health()
        health.dayPlans = [480, 481, 600].enumerated().map {
            .init(date: day.addingTimeInterval(Double($0.offset * 86400)), availableMinutes: 720, plannedMinutes: $0.element)
        }
        let presentation = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertEqual(presentation.heavyDays.map(\.plannedMinutes), [481, 600])
        XCTAssertTrue(presentation.loadSummary.contains("有 2 天"))
        XCTAssertTrue(presentation.loadSummary.contains("10 小时"))
        XCTAssertEqual(ScheduleHealthPresentation(health: health, warningMinutes: -1).warningMinutes, 30)
    }

    func testRecoveryExplainsItIsAlreadyIncludedAndEmptyLoadDoesNotClaimFeasible() {
        var health = health()
        let empty = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertTrue(empty.loadSummary.contains("暂时无法评估"))
        health.recovery = [.init(date: day, availableMinutes: 0, plannedMinutes: 75)]
        let presentation = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertTrue(presentation.recoverySummary.contains("1 小时 15 分"))
        XCTAssertTrue(presentation.recoverySummary.contains("已包含在每日学习量中"))
    }

    func testRecoveryTotalUsesOneDeduplicatedBudgetInsteadOfRawConfirmations() {
        var health = health()
        health.reviewedMinutes = 240
        health.creditedMinutes = 30
        health.recovery = [.init(date: day, availableMinutes: 0, plannedMinutes: 60)]
        health.recoveryUnscheduledMinutes = 15
        let presentation = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertEqual(presentation.recoveryScheduledMinutes, 60)
        XCTAssertEqual(presentation.recoveryRemainingMinutes, 75)
        XCTAssertTrue(presentation.recoverySummary.contains("15 分钟还未排入"))
        health.recovery = []
        let unplaced = ScheduleHealthPresentation(health: health, warningMinutes: 480)
        XCTAssertEqual(unplaced.recoveryRemainingMinutes, 15)
        XCTAssertTrue(unplaced.recoverySummary.contains("目前尚未排入课表"))
        health.recoveryUnscheduledMinutes = 0
        XCTAssertTrue(ScheduleHealthPresentation(health: health, warningMinutes: 480).recoverySummary.contains("没有仍需补学"))
    }

    private func health() -> ScheduleHealth {
        .init(status: .pending, remainingMinutes: 0, unscheduledMinutes: 0, pausedMinutes: 0,
              peakMinutes: 0, heavyDays: 0, averageMinutes: 0, reviewedMinutes: 0, creditedMinutes: 0,
              recovery: [], dayPlans: [])
    }
}
