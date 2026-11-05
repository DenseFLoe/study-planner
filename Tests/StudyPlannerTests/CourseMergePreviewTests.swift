import XCTest
import StudyCore
@testable import StudyPlanner

final class CourseMergePreviewTests: XCTestCase {
    func testPreviewKeepsSourceStateAndUsesMergedProgressAndOrder() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var first = Course(name: "课程1", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
        first.type = .lessonBasedRecorded
        first.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 60)]
        first.initialCompletedMinutes = 10
        var second = Course(name: "课程2", totalMinutes: 90, startDate: now, deadline: now.addingTimeInterval(172800))
        second.type = .lessonBasedRecorded
        second.manualLessons = [.init(id: "second", name: "第二节", durationMinutes: 90)]
        var state = PlannerState(); state.courses = [second, first]
        let task = ScheduledTask(courseID: first.id, start: now, durationMinutes: 30, lessonID: "first")
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now.addingTimeInterval(60))
        let before = state
        let preview = try CourseMergePreview(state: state, selected: [first.id, second.id], name: "  合并预览  ")
        XCTAssertEqual(state, before)
        XCTAssertEqual(preview.course.name, "合并预览")
        XCTAssertEqual(preview.course.totalMinutes, 150)
        XCTAssertEqual(preview.course.deadline, first.deadline)
        XCTAssertEqual(preview.lessons.map(\.id), [first.id.uuidString + "/first", second.id.uuidString + "/second"])
        XCTAssertEqual(preview.lessons.map(\.remainingMinutes), [30, 90])
        XCTAssertEqual(Set(preview.course.mergedSources!.map(\.id)), [first.id, second.id])
        XCTAssertEqual(preview.state.courses.filter(\.isArchived).count, 2)
        XCTAssertEqual(preview.state.tasks.first?.courseID, preview.course.id)
        XCTAssertEqual(preview.state.completions.first?.courseID, preview.course.id)
        XCTAssertEqual(preview.state.remainingMinutes(for: preview.course), 120)
    }

    func testSchedulingPreviewUsesMergedCourseAndPreservesOtherConstraints() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let now = day.addingTimeInterval(9 * 3600)
        let first = Course(name: "来源一", totalMinutes: 20, startDate: day, deadline: day)
        let second = Course(name: "来源二", totalMinutes: 20, startDate: day, deadline: day)
        let other = Course(name: "其他课程", totalMinutes: 20, startDate: day, deadline: day)
        var state = PlannerState(); state.courses = [first, second, other]
        state.settings.availability = [.init(weekday: 2, startMinute: 9 * 60, endMinute: 12 * 60)]
        let event = FixedEvent(title: "保留事项", startMinute: 9 * 60, endMinute: 9 * 60 + 30,
                               startDate: day, endDate: day)
        state.fixedEvents = [event]
        let before = state
        let preview = try CourseMergePreview(state: state, selected: [first.id, second.id], name: "试排合并")
        let result = ScheduleEngine(calendar: calendar).generate(state: preview.state, now: now)
        XCTAssertEqual(state, before)
        XCTAssertEqual(preview.state.fixedEvents, [event])
        XCTAssertEqual(Set(result.demands.keys), [preview.course.id, other.id])
        XCTAssertFalse(result.tasks.isEmpty)
        XCTAssertTrue(result.tasks.allSatisfy { $0.courseID == preview.course.id || $0.courseID == other.id })
        XCTAssertTrue(result.tasks.allSatisfy { $0.start >= day.addingTimeInterval(9.5 * 3600) })
        XCTAssertEqual(result.tasks.filter { $0.courseID == preview.course.id }.reduce(0) { $0 + $1.durationMinutes }, 40)
    }

    func testPreviewReportsInvalidSelectionAndDurationWithoutMutation() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var state = PlannerState()
        state.courses = [Course(name: "大课程", totalMinutes: 600_000, startDate: now, deadline: now),
                         Course(name: "另一门", totalMinutes: 1, startDate: now, deadline: now)]
        let before = state, selected = Set(state.courses.map(\.id))
        for (ids, title) in [(selected, "合并"), (Set([state.courses[0].id, UUID()]), "合并"), (selected, "  ")] {
            XCTAssertThrowsError(try CourseMergePreview(state: state, selected: ids, name: title)) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
            XCTAssertEqual(state, before)
        }
    }
}
