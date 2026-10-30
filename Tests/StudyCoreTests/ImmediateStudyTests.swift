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

    func testSelectedLaterLessonMovesAheadWithoutDroppingOrDuplicatingOtherLessons() throws {
        var state = fixture()
        state.courses[1] = course("乙", lengths: [60, 30, 45, 20])
        state.courses[1].lessonOrder = ["乙-1", "乙-0", "乙-3", "乙-2"]
        let originalCourse = state.courses[1]
        let baseline = state.replan(now: date(), calendar: cal)
        let result = try state.studyImmediately(courseID: originalCourse.id, lessonID: "乙-3",
                                                now: date(28, 8, 0, 14), calendar: cal)
        let booked = result.tasks.filter { $0.courseID == originalCourse.id }
        XCTAssertEqual(result.tasks.first?.lessonID, "乙-3")
        XCTAssertEqual(booked.first?.start, date(28, 8, 1))
        XCTAssertEqual(booked.map(\.lessonID), ["乙-3", "乙-1", "乙-0", "乙-2"])
        XCTAssertEqual(booked.map(\.durationMinutes), [20, 30, 60, 45])
        XCTAssertEqual(totals(result.tasks), totals(baseline.tasks))
        XCTAssertEqual(state.courses[1], originalCourse)
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        for (a, b) in zip(result.tasks, result.tasks.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end.addingTimeInterval(900), b.start)
        }
    }

    func testSelectedPartiallyCompletedLessonOnlySchedulesItsRemainingMinutes() throws {
        var state = fixture()
        let selected = state.courses[1]
        let earlier = ScheduledTask(courseID: selected.id, start: date(28, 6), durationMinutes: 30, lessonID: "乙-1")
        state.tasks = [earlier]
        try state.confirm(taskID: earlier.id, actualMinutes: 10, now: date(28, 6, 10), calendar: cal)
        let completions = state.completions
        let result = try state.studyImmediately(courseID: selected.id, lessonID: "乙-1", now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.lessonID, "乙-1")
        XCTAssertEqual(result.tasks.first?.durationMinutes, 20)
        XCTAssertEqual(result.tasks.filter { $0.courseID == selected.id }.map(\.lessonID), ["乙-1", "乙-0"])
        XCTAssertEqual(state.lessonWorkItems(for: selected).map(\.remainingMinutes), [60, 20])
        XCTAssertEqual(state.completions, completions)
        XCTAssertEqual(totals(result.tasks)[selected.id], 80)
    }

    func testSelectedLessonSurvivesReloadAndCancelRestoresOriginalOrder() throws {
        var state = fixture()
        let selected = state.courses[1]
        let first = try state.studyImmediately(courseID: selected.id, lessonID: "乙-1", now: date(), calendar: cal).tasks.first!
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        let refreshed = state.replan(now: date(28, 8, 5), calendar: cal)
        XCTAssertEqual(refreshed.tasks.first, first)
        XCTAssertEqual(refreshed.tasks.filter { $0.courseID == selected.id }.map(\.lessonID), ["乙-1", "乙-0"])
        state.settings.immediateStudy = nil
        let cancelled = state.replan(now: date(28, 8, 5), calendar: cal)
        assertSchedule(cancelled, state: state)
        XCTAssertEqual(state.completedMinutes(for: selected), 0)
    }

    func testConfirmingSelectedLaterLessonDoesNotCompleteEarlierLessons() throws {
        var state = fixture()
        let selected = state.courses[1]
        let task = try state.studyImmediately(courseID: selected.id, lessonID: "乙-1", now: date(), calendar: cal).tasks.first!
        try state.confirm(taskID: task.id, actualMinutes: task.durationMinutes, now: task.end, calendar: cal)
        let result = state.replan(now: date(28, 8, 45), calendar: cal)
        XCTAssertNil(state.settings.immediateStudy)
        XCTAssertEqual(state.lessonWorkItems(for: selected).map(\.remainingMinutes), [60, 0])
        XCTAssertEqual(result.tasks.filter { $0.courseID == selected.id }.map(\.lessonID), ["乙-0"])
        let original = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: selected.id, lessonID: "乙-1",
                                                       now: date(28, 8, 45), calendar: cal)) {
            XCTAssertEqual($0 as? ImmediateStudyError, .unavailable)
        }
        XCTAssertEqual(state, original)
    }

    func testMissingAndWrongCourseLessonIDsAreRejectedWithoutFallingBackToFirstLesson() {
        for lessonID in ["missing", "甲-1"] {
            var state = fixture()
            let original = state
            XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[1].id, lessonID: lessonID,
                                                           now: date(), calendar: cal)) {
                XCTAssertEqual($0 as? ImmediateStudyError, .unavailable)
            }
            XCTAssertEqual(state, original)
        }
    }

    func testSelectedLessonCanStartWithOneSegmentAndContinueOnAnotherDay() throws {
        var state = fixture()
        state.courses = [course("甲", lengths: [30, 90])]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        let result = try state.studyImmediately(courseID: state.courses[0].id, lessonID: "甲-1",
                                                now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.map(\.lessonID), ["甲-1", "甲-1", "甲-0"])
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [60, 30, 30])
        XCTAssertEqual(result.tasks.first?.start, date())
        XCTAssertGreaterThanOrEqual(result.tasks[1].start, date(29, 0))
        XCTAssertEqual(state.settings.immediateStudy?.continuesLesson, true)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(totals(result.tasks)[state.courses[0].id], 120)
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
        for kind in 0..<4 {
            var state = fixture()
            switch kind {
            case 0: state.courses[0].startDate = date(29, 0)
            case 1: state.courses[0].deadline = date(27, 0)
            case 2: state.settings.availability = []
            default: state.fixedEvents = [.init(title: "固定课", startMinute: 480, endMinute: 560, startDate: date(), endDate: date())]
            }
            let original = state
            XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal))
            XCTAssertEqual(state, original)
        }
    }

    func testNewConstraintKeepsImmediateLessonAndReportsAnyRemainingDeadlineDeficit() throws {
        var state = fixture()
        state.courses = [course("紧急", lengths: [60], deadline: 28), course("选中", lengths: [60], deadline: 29)]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 540) }
        _ = state.replan(now: date(), calendar: cal)
        let result = try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.courseID, state.courses[1].id)
        XCTAssertEqual(result.tasks.first?.start, date())
        XCTAssertEqual(state.settings.immediateStudy?.task, result.tasks.first)
        XCTAssertEqual(result.risks.first?.unscheduledMinutes, 60)
        XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 60)
        XCTAssertTrue(state.completions.isEmpty)
        let refreshed = state.replan(now: date(28, 8, 5), calendar: cal)
        XCTAssertEqual(refreshed.tasks.first?.id, state.settings.immediateStudy?.task.id)
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

    func testConfirmedHistoryAndRestAreProtected() {
        var state = fixture()
        var history = ScheduledTask(courseID: state.courses[2].id, start: date(28, 7), durationMinutes: 60)
        history.status = .completed; history.confirmedAt = date(); history.completedMinutes = 60
        state.tasks = [history]
        let original = state
        XCTAssertThrowsError(try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal))
        XCTAssertEqual(state, original)
    }

    func testUnconfirmedElapsedDraftDoesNotForceRestOrRetainDuplicateWork() throws {
        var state = fixture()
        let old = ScheduledTask(courseID: state.courses[2].id, start: date(28, 7), durationMinutes: 60)
        state.tasks = [old]
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.start, date())
        XCTAssertEqual(state.settings.actualStudyStart, date())
        XCTAssertFalse(state.tasks.contains { $0.id == old.id })
        XCTAssertTrue(state.completions.isEmpty)
        assertSchedule(result, state: state)
    }

    func testNewPlanStartsNowInsteadOfUsingAnOldFutureStartAnchor() throws {
        var state = fixture()
        state.settings.actualStudyStart = date(28, 9)
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.start, date())
        XCTAssertEqual(state.settings.actualStudyStart, date())
        assertSchedule(result, state: state)
    }

    func testNewPlanCanMoveOtherCoursesToLaterDays() throws {
        var state = fixture()
        state.courses = [course("原先优先", lengths: [60]), course("现在选择", lengths: [60])]
        state.courses[0].priority = 5
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 600) }
        let baseline = state.replan(now: date(), calendar: cal)
        XCTAssertEqual(baseline.tasks.first?.courseID, state.courses[0].id)
        let result = try state.studyImmediately(courseID: state.courses[1].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.first?.courseID, state.courses[1].id)
        XCTAssertGreaterThan(try XCTUnwrap(result.tasks.first { $0.courseID == state.courses[0].id }).start, date(29, 0))
        XCTAssertEqual(totals(result.tasks), totals(baseline.tasks))
        assertSchedule(result, state: state)
    }

    func testStartsBeforeLunchWithoutRestFromUnconfirmedDraftAndResumesSameLesson() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [90])]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 540, endMinute: 1320) }
        state.fixedEvents = [.init(title: "午休", startMinute: 720, endMinute: 780, startDate: date(), endDate: date())]
        let old = ScheduledTask(courseID: state.courses[0].id, start: date(28, 10, 55), durationMinutes: 56, lessonID: "选中-0")
        state.tasks = [old]
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: date(28, 11, 58), calendar: cal)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [2, 88])
        XCTAssertEqual(result.tasks.map(\.lessonID), ["选中-0", "选中-0"])
        XCTAssertEqual(result.tasks.map(\.start), [date(28, 11, 58), date(28, 13)])
        XCTAssertFalse(state.tasks.contains { $0.id == old.id })
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 90)
    }

    func testSplitLessonContinuationSurvivesReloadAndConfirmationUntilLessonCompletes() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [30, 90])]
        let originalCourse = state.courses[0]
        state.fixedEvents = [.init(title: "午休", startMinute: 720, endMinute: 780, startDate: date(), endDate: date())]
        let initial = try state.studyImmediately(courseID: originalCourse.id, lessonID: "选中-1", now: date(28, 11, 50), calendar: cal)
        let first = try XCTUnwrap(initial.tasks.first)
        XCTAssertEqual(initial.tasks.map(\.lessonID), ["选中-1", "选中-1", "选中-0"])
        XCTAssertEqual(initial.tasks.map(\.durationMinutes), [10, 80, 30])
        state = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        let refreshed = state.replan(now: date(28, 11, 55), calendar: cal)
        XCTAssertEqual(refreshed.tasks.first, first)
        XCTAssertEqual(totals(refreshed.tasks)[originalCourse.id], 120)
        try state.confirm(taskID: first.id, actualMinutes: 10, now: date(28, 12), calendar: cal)
        let resumed = state.replan(now: date(28, 12, 1), calendar: cal)
        XCTAssertEqual(resumed.tasks.map(\.lessonID), ["选中-1", "选中-0"])
        XCTAssertEqual(resumed.tasks.map(\.durationMinutes), [80, 30])
        XCTAssertEqual(state.immediateStudyContinuation(now: date(28, 12, 1), calendar: cal)?.id, "选中-1")
        let continuation = resumed.tasks[0]
        try state.confirm(taskID: continuation.id, actualMinutes: 80, now: continuation.end, calendar: cal)
        let completed = state.replan(now: continuation.end.addingTimeInterval(900), calendar: cal)
        XCTAssertNil(state.settings.immediateStudy)
        XCTAssertEqual(completed.tasks.map(\.lessonID), ["选中-0"])
        XCTAssertEqual(state.lessonWorkItems(for: originalCourse).map(\.remainingMinutes), [30, 0])
        XCTAssertEqual(state.courses[0], originalCourse)
    }

    func testPartialConfirmationOnlyCreditsActualSegmentMinutes() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [30, 90])]
        state.fixedEvents = [.init(title: "午休", startMinute: 720, endMinute: 780, startDate: date(), endDate: date())]
        let first = try state.studyImmediately(courseID: state.courses[0].id, lessonID: "选中-1", now: date(28, 11, 50), calendar: cal).tasks[0]
        try state.confirm(taskID: first.id, actualMinutes: 5, now: date(28, 11, 55), calendar: cal)
        let result = state.replan(now: date(28, 11, 55), calendar: cal)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [85, 30])
        XCTAssertEqual(result.tasks.first?.lessonID, "选中-1")
        XCTAssertEqual(result.tasks.first?.start, date(28, 13))
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 5)
        XCTAssertEqual(state.settings.immediateStudy?.continuesLesson, true)
    }

    func testExpiredUnconfirmedSegmentKeepsAllMinutesAndDoesNotReplanIntoThePast() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [90])]
        state.fixedEvents = [.init(title: "午休", startMinute: 720, endMinute: 780, startDate: date(), endDate: date())]
        _ = try state.studyImmediately(courseID: state.courses[0].id, now: date(28, 11, 50), calendar: cal)
        let result = state.replan(now: date(28, 13), calendar: cal)
        XCTAssertEqual(result.tasks.first?.start, date(28, 13))
        XCTAssertEqual(totals(result.tasks)[state.courses[0].id], 90)
        XCTAssertTrue(state.completions.isEmpty)
        XCTAssertNotNil(state.settings.immediateStudy)
    }

    func testFloatingEventCanShortenFirstSegmentInsteadOfPreventingStart() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [60])]
        var event = FixedEvent(title: "浮动事项", startMinute: 480, endMinute: 570, startDate: date(), endDate: date())
        event.floatingDurationMinutes = 60
        state.fixedEvents = [event]
        let result = try state.studyImmediately(courseID: state.courses[0].id, now: date(), calendar: cal)
        XCTAssertEqual(result.tasks.map(\.durationMinutes), [30, 30])
        XCTAssertEqual(result.tasks.first?.start, date())
        XCTAssertEqual(totals(result.tasks)[state.courses[0].id], 60)
        XCTAssertTrue(result.risks.isEmpty)
        XCTAssertNotNil(FloatingPlacement.reserve([event, state.immediateStudyReservation(result.tasks[0], calendar: cal)]))
    }

    func testContinuationOutranksSavedFutureDragOrderAndCannotBeDragged() throws {
        var state = fixture()
        state.courses = [course("选中", lengths: [30, 90], deadline: 29)]
        let todayWeekday = cal.component(.weekday, from: date())
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: $0 == todayWeekday ? 540 : 600) }
        let initial = try state.studyImmediately(courseID: state.courses[0].id, lessonID: "选中-1", now: date(), calendar: cal)
        let tomorrow = initial.tasks.filter { cal.isDate($0.start, inSameDayAs: date(29, 0)) }
        XCTAssertEqual(tomorrow.map(\.lessonID), ["选中-1", "选中-0"])
        guard tomorrow.count == 2 else { return }
        state.settings.dailyTaskOrders = [.init(day: date(29, 0), keys: DailyTaskOrder.keys(for: tomorrow).reversed())]
        let refreshed = state.replan(now: date(28, 8, 5), calendar: cal)
        XCTAssertEqual(refreshed.tasks.filter { cal.isDate($0.start, inSameDayAs: date(29, 0)) }.map(\.lessonID), ["选中-1", "选中-0"])
        XCTAssertThrowsError(try state.swapDailyTasks(tomorrow[0].id, tomorrow[1].id, now: date(28, 8, 5), calendar: cal)) {
            XCTAssertEqual($0 as? ImmediateStudyError, .pinnedTask)
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

    func testLegacyImmediateRequestDecodesWithoutContinuationFlag() throws {
        let task = ScheduledTask(courseID: UUID(), start: date(), durationMinutes: 60, lessonID: "legacy")
        let data = try JSONEncoder().encode(ImmediateStudyRequest(task: task))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["continuesLesson"])
        let decoded = try JSONDecoder().decode(ImmediateStudyRequest.self, from: data)
        XCTAssertEqual(decoded.task, task)
        XCTAssertNil(decoded.continuesLesson)
    }
}
