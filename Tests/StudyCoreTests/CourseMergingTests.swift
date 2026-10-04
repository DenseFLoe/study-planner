import XCTest
@testable import StudyCore

final class CourseMergingTests: XCTestCase {
    func testUndoMergedWebsiteCompletionKeepsVerifiedWebsiteProgress() throws {
        for nested in [false, true] {
            let now = Date()
            var state = PlannerState()
            var snapshot = WebCourseSnapshot(packageID: "web", name: "网站课程", sourceURL: "https://example.com",
                fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1,
                lessons: [.init(id: "video", name: "视频", subject: "", stage: "", chapter: "", kind: "video",
                                published: true, durationSeconds: 3600, watchedPercent: 50,
                                markedFinished: false, requiresDuration: true)], issues: [])
            try state.importWebCourses([snapshot], deadline: now.addingTimeInterval(86400), now: now)
            let imported = state.courses[0]
            let task = ScheduledTask(courseID: imported.id, start: now, durationMinutes: 30, lessonID: "video")
            state.tasks = [task]
            try state.confirm(taskID: task.id, actualMinutes: 30, now: now.addingTimeInterval(1))
            snapshot.fetchedAt = now.addingTimeInterval(60); snapshot.lessons[0].watchedPercent = 100
            try state.importWebCourses([snapshot], deadline: now.addingTimeInterval(86400), now: snapshot.fetchedAt)
            let manual = Course(name: "手动", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
            state.courses.append(manual)
            var merged = try state.mergeCourses(ids: [imported.id, manual.id], name: "合并")
            state.removeArchivedCourses()
            if nested {
                let extra = Course(name: "另一门", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
                state.courses.append(extra)
                merged = try state.mergeCourses(ids: [merged.id, extra.id], name: "再次合并")
                state.removeArchivedCourses()
            }
            try state.undoConfirmation(taskID: task.id, now: snapshot.fetchedAt)
            let saved = try XCTUnwrap(state.courses.first { $0.id == merged.id })
            XCTAssertEqual(state.completedMinutes(for: saved), 60)
            XCTAssertEqual(state.lessonWorkItems(for: saved).reduce(0) { $0 + $1.remainingMinutes }, nested ? 120 : 60)
            XCTAssertEqual(state.lessonWorkItems(for: saved).first { $0.id.hasSuffix("/video") }?.remainingMinutes, 0)
        }
    }

    func testMergePreservesProgressIdentityAndCustomOrder() throws {
        let now = Date()
        var first = Course(name: "同一课程", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
        first.type = .lessonBasedRecorded
        first.manualLessons = [.init(id: "same", name: "第10节", durationMinutes: 60)]
        first.initialCompletedMinutes = 10
        var second = first
        second.id = UUID(); second.name = "同一课程"; second.initialCompletedMinutes = 0
        second.manualLessons = [.init(id: "same", name: "第2节", durationMinutes: 60)]
        var state = PlannerState(); state.courses = [first, second]
        let task = ScheduledTask(courseID: first.id, start: now.addingTimeInterval(-3600), durationMinutes: 30, lessonID: "same")
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 20, now: now)
        var merged = try state.mergeCourses(ids: [first.id, second.id], name: "合并")
        XCTAssertEqual(state.courses.filter { !$0.isArchived }.count, 1)
        XCTAssertEqual(state.tasks[0].id, task.id)
        XCTAssertEqual(state.completedMinutes(for: merged), 30)
        XCTAssertEqual(state.lessonWorkItems(for: merged).map(\.name), ["第2节", "第10节"])
        XCTAssertEqual(state.lessonWorkItems(for: merged).map(\.remainingMinutes), [60, 30])
        XCTAssertEqual(Set(state.lessonWorkItems(for: merged).map(\.id)).count, 2)
        merged.lessonOrder = merged.lessonOrder!.reversed()
        XCTAssertEqual(state.lessonWorkItems(for: merged).map(\.name), ["第10节", "第2节"])
        try state.undoConfirmation(taskID: task.id, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: merged).map(\.remainingMinutes), [50, 60])
        XCTAssertEqual(try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state)), state)
    }

    func testNestedMergeAndNewCompletion() throws {
        let now = Date()
        let courses = (1...3).map { Course(name: "课\($0)", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400)) }
        var state = PlannerState(); state.courses = courses
        let first = try state.mergeCourses(ids: [courses[0].id, courses[1].id], name: "第一组")
        let merged = try state.mergeCourses(ids: [first.id, courses[2].id], name: "全部")
        let lesson = state.lessonWorkItems(for: merged)[0]
        let task = ScheduledTask(courseID: merged.id, start: now, durationMinutes: 60, lessonID: lesson.id)
        state.tasks.append(task)
        try state.confirm(taskID: task.id, actualMinutes: 25, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: merged).map(\.remainingMinutes), [35, 60, 60])
        XCTAssertEqual(state.remainingMinutes(for: merged), 155)
    }

    func testInvalidSelectionDoesNotMutateState() throws {
        var state = PlannerState()
        let before = state
        XCTAssertThrowsError(try state.mergeCourses(ids: [UUID(), UUID()], name: "合并"))
        XCTAssertEqual(state, before)
    }

    func testImportedProgressSurvivesMergeAndActiveTasksReplan() throws {
        let now = Date()
        var state = PlannerState()
        let snapshot = WebCourseSnapshot(packageID: "web", name: "网站课程", sourceURL: "https://example.com",
            fetchedAt: now.addingTimeInterval(-7200), expectedOutlines: 1, fetchedOutlines: 1,
            lessons: [.init(id: "video", name: "视频", subject: "", stage: "", chapter: "", kind: "video",
                            published: true, durationSeconds: 3600, watchedPercent: 50,
                            markedFinished: false, requiresDuration: true)], issues: [])
        try state.importWebCourses([snapshot], deadline: now.addingTimeInterval(86400), now: now)
        let imported = state.courses[0]
        let manual = Course(name: "手动", totalMinutes: 60, startDate: now, deadline: now.addingTimeInterval(86400))
        state.courses.append(manual)
        let active = ScheduledTask(courseID: imported.id, start: now.addingTimeInterval(-60), durationMinutes: 30, lessonID: "video")
        state.tasks = [active]
        let merged = try state.mergeCourses(ids: [imported.id, manual.id], name: "合并")
        XCTAssertEqual(state.lessonWorkItems(for: merged).reduce(0) { $0 + $1.remainingMinutes }, 90)
        XCTAssertEqual(merged.mergedSources?.first(where: { $0.id == imported.id })?.webCourse, snapshot)
        _ = state.replan(now: now)
        XCTAssertNil(state.tasks.first(where: { $0.id == active.id }))
        let replacement = try XCTUnwrap(state.tasks.first { $0.lessonID == imported.id.uuidString + "/video" })
        XCTAssertGreaterThanOrEqual(replacement.start, now)
        try state.confirm(taskID: replacement.id, actualMinutes: 20, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: merged).reduce(0) { $0 + $1.remainingMinutes }, 70)
    }
}
