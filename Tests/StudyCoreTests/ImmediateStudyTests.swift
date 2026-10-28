import XCTest
@testable import StudyCore

final class ImmediateStudyTests: XCTestCase {
    private var cal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private func date(_ day: Int = 28, _ hour: Int = 8, _ minute: Int = 0, _ second: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }
    private func course(_ name: String, lengths: [Int] = [60, 30], deadline: Int = 30) -> Course {
        var course = Course(name: name, totalMinutes: lengths.reduce(0, +), startDate: date(28, 0), deadline: date(deadline, 0))
        course.type = .lessonBasedRecorded
        course.manualLessons = lengths.enumerated().map { .init(id: "\(name)-\($0.offset)", name: "第\($0.offset + 1)节", durationMinutes: $0.element) }
        return course
    }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        state.courses = [course("甲"), course("乙"), course("丙")]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 1080) }
        return state
    }
    private func totals(_ tasks: [ScheduledTask]) -> [UUID: Int] {
        Dictionary(grouping: tasks, by: \.courseID).mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }
    }
    private func assertSchedule(_ result: ScheduleResult, state: PlannerState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.risks.isEmpty, file: file, line: line)
        let tasks = result.tasks.sorted { $0.start < $1.start }
        for (a, b) in zip(tasks, tasks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end.addingTimeInterval(900), b.start, file: file, line: line)
        }
        for course in state.courses {
            let lessons = state.lessonWorkItems(for: course).filter { $0.remainingMinutes > 0 }
            let booked = tasks.filter { $0.courseID == course.id }
            XCTAssertEqual(booked.map(\.lessonID), lessons.map { Optional($0.id) }, file: file, line: line)
            XCTAssertEqual(booked.map(\.durationMinutes), lessons.map(\.remainingMinutes), file: file, line: line)
            XCTAssertEqual(totals(tasks)[course.id], state.remainingMinutes(for: course), file: file, line: line)
        }
    }

    func testNextUnfinishedLessonWinsOverSoftPreferencesAndReplansWholeSchedule() throws {
        var state = fixture()
        state.courses[0].priority = 5
        state.courses[0].dailyStudyWeight = 3
        state.courses[1].initialCompletedMinutes = 15
        let selected = state.courses[1].id
        let baseline = state.replan(now: date(), calendar: cal)
        let originalHistory = state.completions
        let result = try state.studyImmediately(courseID: selected, now: date(28, 8, 0, 14), calendar: cal)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(task.courseID, selected)
        XCTAssertEqual(task.start, date(28, 8, 1))
        XCTAssertEqual(task.lessonID, "乙-0")
        XCTAssertEqual(task.durationMinutes, 45)
        XCTAssertEqual(totals(result.tasks), totals(baseline.tasks))
        XCTAssertEqual(state.completions, originalHistory)
        assertSchedule(result, state: state)
        XCTAssertTrue(result.dayPlans.allSatisfy { $0.plannedMinutes <= $0.availableMinutes })
    }

    func testRequestSurvivesReloadAndChangesWithoutDuplicateWork() throws {
        var state = fixture()
        let selected = state.courses[1].id
        let first = try state.studyImmediately(courseID: selected, now: date(), calendar: cal).tasks.first!
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        state.courses[0].dailyStudyWeight = 3
        var settings = state.settings
        settings.immediateStudy = nil // A settings editor may hold a stale copy.
        settings.schedulingRuleLevels = ["balancedLoad": 1, "diversity": 4]
        state.updateStudySettings(settings, now: date(28, 8, 10), calendar: cal)
        let result = state.replan(now: date(28, 8, 10), calendar: cal)
        XCTAssertEqual(result.tasks.first, first)
        XCTAssertEqual(state.tasks.filter { $0.id == first.id }.count, 1)
        assertSchedule(result, state: state)
    }

    func testDateWindowAndFixedConflictsFailAtomically() {
        for kind in 0..<6 {
            var state = fixture()
            switch kind {
            case 0: state.courses[0].startDate = date(29, 0)
            case 1: state.courses[0].deadline = date(27, 0)
            case 2: state.settings.availability = []
            case 3: state.settings.availability = [.init(weekday: cal.component(.weekday, from: date()), startMinute: 480, endMinute: 510)]
            case 4: state.fixedEvents = [.init(title: "固定课", startMinute: 500, endMinute: 560, startDate: date(), endDate: date())]
            default: state.settings.actualStudyStart = date(28, 9)
            }
            let original = state
            XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal))
            XCTAssertEqual(state, original)
        }
    }

    func testRejectsSacrificingCourseDueTodayEvenWhenSelectedCourseFitsNow() {
        var state = fixture()
        state.courses = [course("紧急", lengths: [60], deadline: 28), course("选中", lengths: [60], deadline: 29)]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        _ = state.replan(now: date(), calendar: cal)
        let original = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal)) {
            XCTAssertEqual($0 as? ImmediateStudyError, .noFeasiblePlan)
        }
        XCTAssertEqual(state, original)
    }

    func testMovesUrgentCourseLaterWhenItsDeadlineStillFits() throws {
        var state = fixture()
        state.courses = [course("紧急", lengths: [60], deadline: 28), course("选中", lengths: [30], deadline: 29)]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let result = try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.courseID, state.courses[1].id)
        XCTAssertEqual(result.tasks.first { $0.courseID == state.courses[0].id }?.start, date(28, 8, 45))
        assertSchedule(result, state: state)
    }

    func testFloatingEventsMoveAroundPinnedLessonButCannotOverlapIt() throws {
        var state = fixture()
        var event = FixedEvent(title: "浮动事项", startMinute: 480, endMinute: 660, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 60
        state.fixedEvents = [event]
        let result = try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal)
        let immediate = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(immediate.start, date())
        XCTAssertFalse(immediate.isFloating)
        assertSchedule(result, state: state)
        let reserved = state.immediateStudyReservation(immediate, calendar: cal)
        XCTAssertNotNil(FloatingPlacement.reserve([event, reserved]))
        state.settings.immediateStudy = nil
        event.endMinute = 540
        state.fixedEvents = [event]
        let original = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal))
        XCTAssertEqual(state, original)
    }

    func testRetainedHistoryAndRestAreProtected() {
        for completed in [false, true] {
            var state = fixture()
            var history = ScheduledTask(courseID: state.courses[2].id, start: date(28, 7), durationMinutes: 60)
            if completed { history.status = .completed; history.confirmedAt = date(); history.completedMinutes = 60 }
            state.tasks = [history]
            let original = state
            XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal))
            XCTAssertEqual(state, original)
        }
    }

    func testChangedHardConstraintOverridesSavedRequest() throws {
        var state = fixture()
        let task = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal).tasks.first!
        state.fixedEvents = [.init(title: "新增固定课", startMinute: 480, endMinute: 600, startDate: date(), endDate: date())]
        let result = state.replan(now: date(28, 8, 10), calendar: cal)
        XCTAssertNil(state.settings.immediateStudy)
        XCTAssertFalse(result.tasks.contains { $0.id == task.id })
        XCTAssertTrue(result.tasks.allSatisfy { $0.start >= date(28, 10) })
        assertSchedule(result, state: state)
    }

    func testConfirmationAndExpirationReleaseRequestWithoutCreditingUnstudiedTime() throws {
        for confirm in [false, true] {
            var state = fixture()
            let task = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal).tasks.first!
            if confirm { try state.confirm(taskID: task.id, actualMinutes: 15, now: date(28, 8, 15)) }
            let result = state.replan(now: confirm ? date(28, 8, 15) : task.end, calendar: cal)
            XCTAssertNil(state.settings.immediateStudy)
            XCTAssertEqual(state.completedMinutes(for: state.courses[0]), confirm ? 15 : 0)
            XCTAssertEqual(totals(result.tasks)[state.courses[0].id], confirm ? 75 : 90)
        }
    }

    func testPinnedTaskCannotBeDraggedAndReplacementRemovesOldPin() throws {
        var state = fixture()
        let first = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal)
        let pin = first.tasks.first!
        let other = first.tasks.first { $0.courseID != pin.courseID }!
        XCTAssertThrowsError(try state.swapDailyTasks(pin.id, other.id, now: date(), calendar: cal))
        let second = try state.studyImmediately(courseID: state.courses[1].id, now: date(28, 8, 5), calendar: cal)
        XCTAssertEqual(second.tasks.first?.courseID, state.courses[1].id)
        XCTAssertFalse(second.tasks.contains { $0.id == pin.id })
        assertSchedule(second, state: state)
    }

    func testCompletedPausedAndNonLessonCoursesAreNotCandidates() {
        var state = fixture()
        state.courses[0].autoScheduleEnabled = false
        state.courses[1].initialCompletedMinutes = 90
        state.courses[2].type = .recorded
        XCTAssertTrue(state.immediateStudyCourses.isEmpty)
        let original = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal))
        XCTAssertEqual(state, original)
    }

    func testSavedDragOrderCannotMoveImmediateLessonAndCompletionSelectsNextLesson() throws {
        var state = fixture()
        let draft = state.replan(now: date(), calendar: cal)
        let today = draft.tasks.filter { cal.isDate($0.start, inSameDayAs: date()) }
        state.settings.dailyTaskOrders = [.init(day: date(), keys: DailyTaskOrder.keys(for: today).reversed())]
        let first = try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal).tasks.first!
        XCTAssertEqual(first.courseID, state.courses[1].id)
        try state.confirm(taskID: first.id, actualMinutes: first.durationMinutes, now: date(28, 9), calendar: cal)
        let next = try state.studyImmediately(courseID: state.courses[1].id, now: date(28, 9, 15), calendar: cal).tasks.first!
        XCTAssertEqual(next.lessonID, "乙-1")
        XCTAssertEqual(next.durationMinutes, 30)
        XCTAssertEqual(state.tasks.first { $0.id == first.id }?.confirmedAt, date(28, 9))
        XCTAssertEqual(state.completedMinutes(for: state.courses[1]), 60)
    }

    func testLegacySettingsDecodeWithoutImmediateRequest() throws {
        let data = try JSONEncoder().encode(AppSettings())
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertNil(settings.immediateStudy)
    }
}
