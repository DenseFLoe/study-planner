import XCTest
@testable import StudyCore

final class LessonProgressIndexTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testLargeManualAndWebsiteCoursesKeepEveryConfirmationOnItsLesson() {
        let count = 5_000
        for website in [false, true] {
            var course = Course(name: "大课程", totalMinutes: count * 60, startDate: now,
                                deadline: now.addingTimeInterval(86400 * 365))
            course.type = .lessonBasedRecorded
            if website {
                course.webCourse = WebCourseSnapshot(packageID: "large", name: course.name, sourceURL: "https://example.com/course",
                    fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1,
                    lessons: (0..<count).map { .init(id: "lesson-\($0)", name: "课节 \($0)", subject: "", stage: "", chapter: "", kind: "video",
                        published: true, durationSeconds: 3600, watchedPercent: 50, markedFinished: false, requiresDuration: true) }, issues: [])
                course.initialCompletedMinutes = count * 30
            } else {
                course.manualLessons = (0..<count).map { .init(id: "lesson-\($0)", name: "课节 \($0)", durationMinutes: 60) }
            }
            course.lessonOrder = (0..<count).reversed().map { "lesson-\($0)" }
            var state = PlannerState(); state.courses = [course]
            for index in (0..<count).reversed() {
                let minutes = index % 3 + 1
                var task = ScheduledTask(courseID: course.id, start: now, durationMinutes: 60, lessonID: "lesson-\(index)")
                task.completedMinutes = minutes; task.confirmedAt = now.addingTimeInterval(60); task.status = .partial
                state.tasks.append(task)
                state.completions.append(.init(courseID: course.id, taskID: task.id, minutes: minutes, recordedAt: now.addingTimeInterval(60)))
            }
            let before = state
            let items = state.lessonWorkItems(for: course)
            XCTAssertEqual(items.map(\.id), course.lessonOrder)
            XCTAssertEqual(items.map(\.remainingMinutes), (0..<count).reversed().map { (website ? 30 : 60) - ($0 % 3 + 1) })
            XCTAssertEqual(state, before)
        }
    }

    func testUnidentifiedLegacyCreditStillUsesTheOriginalCourseOrder() {
        var course = Course(name: "旧记录", totalMinutes: 120, startDate: now, deadline: now)
        course.type = .lessonBasedRecorded; course.initialCompletedMinutes = 10
        course.manualLessons = [.init(id: "first", name: "第一节", durationMinutes: 60), .init(id: "second", name: "第二节", durationMinutes: 60)]
        course.lessonOrder = ["second", "first"]
        var state = PlannerState(); state.courses = [course]
        let identified = ScheduledTask(courseID: course.id, start: now, durationMinutes: 60, lessonID: "second")
        let unknown = ScheduledTask(courseID: course.id, start: now, durationMinutes: 60, lessonID: "unknown")
        state.tasks = [identified, unknown]
        state.completions = [.init(courseID: course.id, taskID: identified.id, minutes: 20, recordedAt: now),
                             .init(courseID: course.id, taskID: unknown.id, minutes: 5, recordedAt: now),
                             .init(courseID: course.id, taskID: UUID(), minutes: 7, recordedAt: now)]
        let before = state, items = state.lessonWorkItems(for: course)
        XCTAssertEqual(items.map(\.id), ["second", "first"])
        XCTAssertEqual(items.map(\.remainingMinutes), [40, 38])
        XCTAssertEqual(state, before)
    }
}
