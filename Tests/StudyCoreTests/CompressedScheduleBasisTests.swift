import XCTest
@testable import StudyCore

final class CompressedScheduleBasisTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 8))! }
    private func fixture() -> PlannerState {
        var state = PlannerState()
        var course = Course(name: "课程", totalMinutes: 120, startDate: now, deadline: now)
        course.type = .lessonBasedRecorded
        course.manualLessons = [.init(id: "a", name: "第一讲", durationMinutes: 60), .init(id: "b", name: "第二讲", durationMinutes: 60)]
        state.courses = [course]
        state.settings.availability = (1...7).map { .init(weekday: $0, startMinute: 480, endMinute: 720) }
        return state
    }
    private func matches(_ a: PlannerState, _ b: PlannerState, at date: Date? = nil) -> Bool {
        CompressedScheduleBasis(state: a).matches(.init(state: b), now: date ?? now, calendar: calendar)
    }

    func testLessonOrderDurationAndCourseMembershipAreStructural() {
        let state = fixture()
        var next = state; next.courses[0].lessonOrder = ["b", "a"]
        XCTAssertFalse(matches(state, next))
        next = state; next.courses[0].manualLessons?[0].durationMinutes += 1; next.courses[0].totalMinutes += 1
        XCTAssertFalse(matches(state, next))
        next = state; next.courses.removeAll()
        XCTAssertFalse(matches(state, next))
        next = state; next.courses.append(Course(name: "新增课程", totalMinutes: 60, startDate: now, deadline: now))
        XCTAssertFalse(matches(state, next))
        var reordered = next; reordered.courses.reverse()
        XCTAssertTrue(matches(next, reordered))
    }

    func testWebsiteProgressAndFetchMetadataDoNotChangeStructure() {
        var state = fixture()
        let lessons = ["a", "b"].map {
            WebCourseLesson(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video", published: true,
                            durationSeconds: 3600, watchedPercent: 0, markedFinished: false, requiresDuration: true)
        }
        state.courses[0].manualLessons = nil
        state.courses[0].webCourse = .init(packageID: "synthetic", name: "课程", sourceURL: "https://example.test/course",
            fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1, lessons: lessons, issues: [])
        var next = state
        next.courses[0].webCourse?.fetchedAt = now.addingTimeInterval(86400)
        next.courses[0].webCourse?.lessons[0].watchedPercent = 100
        next.courses[0].webCourse?.lessons[0].markedFinished = true
        next.courses[0].initialCompletedMinutes = 60
        XCTAssertTrue(matches(state, next))
        next.courses[0].webCourse?.lessons[1].durationSeconds = 7200
        next.courses[0].totalMinutes = 180
        XCTAssertFalse(matches(state, next))
    }

    func testFutureFixedRemovalFloatingDurationAndExclusionsAreStructural() {
        var state = fixture()
        var event = FixedEvent(title: "固定事项", startMinute: 600, endMinute: 660, startDate: now, endDate: now.addingTimeInterval(7 * 86400), weekdays: Set(1...7))
        event.floatingDurationMinutes = 30
        state.fixedEvents = [event]
        var next = state; next.fixedEvents = []
        XCTAssertFalse(matches(state, next))
        next = state; next.fixedEvents[0].floatingDurationMinutes = 45
        XCTAssertFalse(matches(state, next))
        next = state; next.fixedEvents[0].excludedDates = [calendar.startOfDay(for: now.addingTimeInterval(86400))]
        XCTAssertFalse(matches(state, next))
        next = state; next.fixedEvents[0].id = UUID(); next.fixedEvents[0].title = "改名"
        XCTAssertTrue(matches(state, next))
    }

    func testElapsedFixedEventsAndHistoricalRecurringChangesDoNotWakeBaseline() {
        var state = fixture()
        let yesterday = calendar.startOfDay(for: now.addingTimeInterval(-86400))
        state.fixedEvents = [.init(title: "已过去", startMinute: 480, endMinute: 540, startDate: yesterday, endDate: yesterday)]
        var next = state; next.fixedEvents = []
        XCTAssertTrue(matches(state, next))
        state.fixedEvents[0].startDate = calendar.startOfDay(for: now)
        state.fixedEvents[0].endDate = calendar.startOfDay(for: now)
        XCTAssertTrue(matches(state, next, at: now.addingTimeInterval(7200)))
        state.fixedEvents = [.init(title: "重复课程", startMinute: 600, endMinute: 660, startDate: yesterday,
            endDate: now.addingTimeInterval(7 * 86400), weekdays: Set(1...7))]
        next = state; next.fixedEvents[0].startDate = calendar.startOfDay(for: now)
        next.fixedEvents[0].excludedDates = [yesterday]
        XCTAssertTrue(matches(state, next))
    }

    func testEditingTitleOfStartedRecurringEventKeepsEquivalentFutureOccupancy() throws {
        var state = fixture()
        state.fixedEvents = [.init(title: "重复课程", startMinute: 480, endMinute: 540,
            startDate: now.addingTimeInterval(-86400), endDate: now.addingTimeInterval(14 * 86400), weekdays: Set(1...7))]
        var next = state
        var edited = state.fixedEvents[0]; edited.title = "改名"
        let duringClass = now.addingTimeInterval(1800)
        try next.updateFixedEvent(edited, now: duringClass, calendar: calendar)
        XCTAssertTrue(matches(state, next, at: duringClass))
        next = state
        edited.endMinute = 600
        try next.updateFixedEvent(edited, now: duringClass, calendar: calendar)
        XCTAssertFalse(matches(state, next, at: duringClass))
    }
}
