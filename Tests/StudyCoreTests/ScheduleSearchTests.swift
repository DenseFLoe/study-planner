import XCTest
import StudyCore

final class ScheduleSearchTests: XCTestCase {
    func testDateTermsUseLocalGregorianDatesAndComposeWithNormalizedNames() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let midnight = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 11, day: 4)))
        let course = Course(name: "Math 高数", totalMinutes: 120, startDate: midnight, deadline: midnight)
        let before = ScheduledTask(courseID: course.id, start: midnight.addingTimeInterval(-60), durationMinutes: 1, lessonName: "第一课")
        let after = ScheduledTask(courseID: course.id, start: midnight.addingTimeInterval(60), durationMinutes: 30, lessonName: "第二课")
        let tasks = [after, before]
        func search(_ term: String, _ scope: ScheduleSearchScope = .all, _ zone: Calendar) -> [UUID] {
            ScheduleSearch.matches(query: term, tasks: tasks, courses: [course], scope: scope,
                                   now: midnight.addingTimeInterval(3600), calendar: zone).map(\.id)
        }
        XCTAssertEqual(search("ＭＡＴＨ　２０２６－１１－０４", .upcoming, calendar), [after.id])
        XCTAssertEqual(search("高数 2026-11-03", .history, calendar), [before.id])
        XCTAssertEqual(search("2026-11", .all, calendar), [before.id, after.id])
        XCTAssertTrue(search("第二课 2026-11-03", .all, calendar).isEmpty)
        var utc = calendar
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(search("2026-11-03", .all, utc), [before.id, after.id], "Date matching must use the calendar's time zone")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        XCTAssertEqual(search("2026-11-04", .all, buddhist), [after.id], "ISO date queries remain Gregorian")
    }

    func testScopesSeparatePendingPlansFromHistoryWithStableOrdering() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: .init(year: 2026, month: 11, day: 4))!
        let course = Course(name: "数学", totalMinutes: 600, startDate: today, deadline: today)
        let oldPending = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(-86400), durationMinutes: 60)
        let endedAtMidnight = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(-3600), durationMinutes: 60)
        let overnight = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(-1800), durationMinutes: 60)
        let earlierToday = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(3600), durationMinutes: 60)
        let future = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(86400), durationMinutes: 60)
        var confirmedFuture = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(2 * 86400), durationMinutes: 60)
        confirmedFuture.confirmedAt = today
        confirmedFuture.status = .completed
        let tasks = [future, oldPending, confirmedFuture, earlierToday, overnight, endedAtMidnight]
        func search(_ scope: ScheduleSearchScope) -> [UUID] {
            ScheduleSearch.matches(query: "数学", tasks: tasks, courses: [course], scope: scope,
                                   now: today.addingTimeInterval(12 * 3600), calendar: calendar).map(\.id)
        }
        XCTAssertEqual(search(.upcoming), [overnight.id, earlierToday.id, future.id])
        XCTAssertEqual(search(.history), [confirmedFuture.id, endedAtMidnight.id, oldPending.id])
        XCTAssertEqual(search(.all), [oldPending.id, endedAtMidnight.id, overnight.id, earlierToday.id, future.id, confirmedFuture.id])
        XCTAssertEqual(Set(search(.upcoming) + search(.history)), Set(tasks.map(\.id)))
    }

    func testFloatingWindowCrossingTodayRemainsUpcomingAndArchiveStaysHidden() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: .init(year: 2026, month: 11, day: 4))!
        var course = Course(name: "数学", totalMinutes: 60, startDate: today, deadline: today)
        var task = ScheduledTask(courseID: course.id, start: today.addingTimeInterval(-7200), durationMinutes: 30)
        task.floatingWindowStart = task.start
        task.floatingWindowEnd = today.addingTimeInterval(3600)
        XCTAssertEqual(ScheduleSearch.matches(query: "数学", tasks: [task], courses: [course], scope: .upcoming,
                                            now: today, calendar: calendar).map(\.id), [task.id])
        course.isArchived = true
        XCTAssertTrue(ScheduleSearch.matches(query: "数学", tasks: [task], courses: [course], scope: .upcoming,
                                            now: today, calendar: calendar).isEmpty)
    }

    func testSearchFindsLessonAcrossDatesAndCoursesInDateOrder() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        let politics = Course(name: "政治强化", totalMinutes: 120, startDate: day, deadline: day)
        let math = Course(name: "高等数学", totalMinutes: 60, startDate: day, deadline: day)
        let first = ScheduledTask(courseID: politics.id, start: day, durationMinutes: 60, lessonName: "简单商品经济（上）")
        let second = ScheduledTask(courseID: politics.id, start: day.addingTimeInterval(86400), durationMinutes: 60, lessonName: "简单商品经济（下）")
        let unrelated = ScheduledTask(courseID: math.id, start: day, durationMinutes: 60, lessonName: "极限")
        let tasks = [second, unrelated, first]
        XCTAssertEqual(ScheduleSearch.matches(query: " 简单商品经济 \n", tasks: tasks, courses: [politics, math]).map(\.id), [first.id, second.id])
        XCTAssertEqual(ScheduleSearch.matches(query: "政治 上", tasks: tasks, courses: [politics, math]).map(\.id), [first.id])
        XCTAssertEqual(ScheduleSearch.matches(query: "高等数学", tasks: tasks, courses: [politics, math]).map(\.id), [unrelated.id])
        XCTAssertTrue(ScheduleSearch.matches(query: "不存在", tasks: tasks, courses: [politics, math]).isEmpty)
        XCTAssertTrue(ScheduleSearch.matches(query: " \n", tasks: tasks, courses: [politics, math]).isEmpty)
    }

    func testArchivedCourseMatchesOnlyVisibleHistory() {
        let day = Date(timeIntervalSince1970: 1_791_000_000)
        var course = Course(name: "政治", totalMinutes: 120, startDate: day, deadline: day)
        course.isArchived = true
        let pending = ScheduledTask(courseID: course.id, start: day, durationMinutes: 60, lessonName: "简单商品经济")
        var confirmed = pending
        confirmed.id = UUID()
        confirmed.confirmedAt = day
        XCTAssertEqual(ScheduleSearch.matches(query: "简单商品经济", tasks: [pending, confirmed], courses: [course]).map(\.id), [confirmed.id])
    }

    func testFilteredConfirmationRowsDoNotSilentlyChangeTheSubmissionScope() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: .init(year: 2026, month: 11, day: 4))!, now = day + 86400
        var state = PlannerState()
        state.courses = [Course(name: "数学", totalMinutes: 120, startDate: day, deadline: now),
                         Course(name: "政治", totalMinutes: 120, startDate: day, deadline: now)]
        state.tasks = state.courses.enumerated().map { ScheduledTask(courseID: $0.element.id, start: day + Double($0.offset) * 7200, durationMinutes: 60) }
        let first = state.tasks[0], hidden = state.tasks[1], before = state
        let matches = ScheduleSearch.matches(query: "数学 ２０２６－１１－０４", tasks: state.tasks, courses: state.courses, calendar: calendar)
        XCTAssertEqual(matches, [first]); XCTAssertEqual(state, before)
        let bothSelected = try ConfirmationBatchDraft(reviewed: state.tasks, minutes: [first.id: 20, hidden.id: 20], studyDates: [:], now: now, calendar: calendar)
        state.tasks[1].durationMinutes = 30; let latest = state
        XCTAssertThrowsError(try bothSelected.apply(to: &state, now: now))
        XCTAssertEqual(state, latest, "A conflict in a selected row remains relevant even when that row is hidden by a filter")
        let onlyMatching = try ConfirmationBatchDraft(reviewed: matches, minutes: [first.id: 20, hidden.id: -1], studyDates: [:], now: now, calendar: calendar)
        try onlyMatching.apply(to: &state, now: now)
        XCTAssertEqual(state.completions.map(\.taskID), [first.id]); XCTAssertEqual(state.tasks[1], latest.tasks[1])
    }

}
