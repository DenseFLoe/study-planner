import XCTest
@testable import StudyCore

final class WebCourseSnapshotTests: XCTestCase {
    func testRefreshCombinesWebsiteAndLocalProgressOnDifferentLessons() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons = ["first", "second"].map {
            .init(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video",
                  published: true, durationSeconds: 3600, watchedPercent: 0,
                  markedFinished: false, requiresDuration: true)
        }
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: "second")
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 60, now: now.addingTimeInterval(1))
        value.fetchedAt = now.addingTimeInterval(60)
        value.lessons[0].watchedPercent = 50
        try state.importWebCourses([value], deadline: deadline, now: value.fetchedAt)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 90)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [30, 0])
        // Repeated refreshes must neither restore completed work nor credit it twice.
        try state.importWebCourses([value], deadline: deadline, now: value.fetchedAt)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 90)
        try state.undoConfirmation(taskID: task.id, now: value.fetchedAt)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [30, 60])
    }

    func testReimportingAnOlderSnapshotKeepsNewerLocalProgress() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons[0].durationSeconds = 3600
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 30, lessonID: value.lessons[0].id)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 30, now: now.addingTimeInterval(1))
        try state.importWebCourses([value], deadline: deadline, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 60)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [0])
    }

    func testRefreshKeepsStudyCompletedBeyondAnExistingWebsiteBaseline() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons[0].durationSeconds = 3600
        let completedID = value.lessons[0].id
        value.lessons.insert(.init(id: "untouched", name: "未学习", subject: "", stage: "", chapter: "", kind: "video",
                                  published: true, durationSeconds: 3600, watchedPercent: 0,
                                  markedFinished: false, requiresDuration: true), at: 0)
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 30, lessonID: completedID)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 30, now: now.addingTimeInterval(1))
        for percent in [50.0, 50.0, 100.0] {
            value.fetchedAt = value.fetchedAt.addingTimeInterval(60)
            value.lessons[1].watchedPercent = percent
            try state.importWebCourses([value], deadline: deadline, now: value.fetchedAt)
            XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 60)
            XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [60, 0])
        }
        try state.undoConfirmation(taskID: task.id, now: value.fetchedAt)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 60)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [60, 0])
    }

    func testRefreshPreservesLocalLessonCompletionUntilWebsiteCatchesUp() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons = ["first", "second"].map {
            .init(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video",
                  published: true, durationSeconds: 3600, watchedPercent: 0,
                  markedFinished: false, requiresDuration: true)
        }
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: "second")
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 60, now: now.addingTimeInterval(1))
        for percent in [0.0, 50.0, 100.0] {
            value.fetchedAt = value.fetchedAt.addingTimeInterval(60)
            value.lessons[1].watchedPercent = percent
            try state.importWebCourses([value], deadline: deadline, now: value.fetchedAt)
            let items = state.lessonWorkItems(for: state.courses[0])
            XCTAssertEqual(items.map(\.remainingMinutes), [60, 0], "website progress: \(percent)")
            XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 60)
            let plan = ScheduleEngine().generate(state: state, now: value.fetchedAt)
            XCTAssertEqual(plan.tasks.map(\.lessonID), ["first"])
        }
    }

    func testRefreshDoesNotCreditWebsiteProgressTwiceAcrossLessons() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons = ["first", "second", "third"].map {
            .init(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video",
                  published: true, durationSeconds: 3600, watchedPercent: 0,
                  markedFinished: false, requiresDuration: true)
        }
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        for id in ["second", "third"] {
            let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: id)
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 30, now: now.addingTimeInterval(1))
        }
        value.fetchedAt = now.addingTimeInterval(60)
        value.lessons[1].watchedPercent = 50
        try state.importWebCourses([value], deadline: deadline, now: value.fetchedAt)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [60, 30, 30])
        let restored = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.lessonWorkItems(for: restored.courses[0]).map(\.remainingMinutes), [60, 30, 30])
        try state.undoConfirmation(taskID: state.tasks[1].id, now: value.fetchedAt)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [60, 30, 60])
    }

    func testRepeatedLessonHistoryNeverCompletesUntouchedLessons() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400 * 7)
        var value = snapshot()
        value.fetchedAt = now
        value.lessons = ["untouched", "repeated", "later"].map {
            .init(id: $0, name: $0, subject: "", stage: "", chapter: "", kind: "video",
                  published: true, durationSeconds: 3600, watchedPercent: 0,
                  markedFinished: false, requiresDuration: true)
        }
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        // Reproduce old/offline records whose sum even exceeds the whole course.
        for id in ["repeated", "repeated", "repeated", "repeated", "later"] {
            var task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: id)
            task.confirmedAt = now.addingTimeInterval(1)
            task.completedMinutes = 60; task.status = .completed
            state.tasks.append(task)
            state.completions.append(.init(courseID: task.courseID, taskID: task.id, minutes: 60, recordedAt: task.confirmedAt!))
        }
        for fetchedAt in [now, now.addingTimeInterval(2)] {
            state.courses[0].webCourse!.fetchedAt = fetchedAt
            XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [60, 0, 0])
            XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 120)
            let plan = ScheduleEngine().generate(state: state, now: now.addingTimeInterval(3))
            XCTAssertEqual(Set(plan.tasks.compactMap(\.lessonID)), ["untouched"])
        }
        let restored = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.remainingMinutes(for: restored.courses[0]), 60)
        XCTAssertEqual(restored.completions.count, 5, "Keep the original study history")
    }

    func testConfirmingAnotherTaskForFinishedLessonAddsNoProgress() throws {
        let now = Date()
        var value = snapshot()
        value.fetchedAt = now
        value.lessons[0].durationSeconds = 3600
        value.lessons[0].watchedPercent = 0
        value.lessons.append(.init(id: "untouched", name: "未学习", subject: "", stage: "", chapter: "", kind: "video",
                                  published: true, durationSeconds: 3600, watchedPercent: 0, markedFinished: false, requiresDuration: true))
        var state = PlannerState()
        try state.importWebCourses([value], deadline: now.addingTimeInterval(86400), now: now)
        for _ in 0..<2 {
            let task = ScheduledTask(courseID: state.courses[0].id, start: now, durationMinutes: 60, lessonID: value.lessons[0].id)
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 60, now: now.addingTimeInterval(1))
        }
        XCTAssertEqual(state.completions.map(\.minutes), [60, 0])
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.remainingMinutes), [0, 60])
        try state.undoConfirmation(taskID: state.tasks[1].id, now: now.addingTimeInterval(2))
        XCTAssertEqual(state.remainingMinutes(for: state.courses[0]), 60)
    }

    func snapshot() -> WebCourseSnapshot {
        .init(packageID: "1", name: "数学", sourceURL: "https://www.kaoyanvip.cn/", fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
              lessons: [.init(id: "1:1", name: "课节", subject: "数学", stage: "基础", chapter: "一", kind: "video", published: true, durationSeconds: 3601, watchedPercent: 50, markedFinished: false, requiresDuration: true)], issues: [])
    }
    func testRoundOnceAndIdempotentImport() throws {
        let value = snapshot(), now = Date(), deadline = Date().addingTimeInterval(86400)
        XCTAssertEqual(value.totalMinutes, 61)
        XCTAssertEqual(value.completedMinutes, 30)
        XCTAssertEqual(value.remainingMinutes, 31)
        var state = PlannerState()
        try state.importWebCourses([value], deadline: deadline, now: now)
        let id = state.courses[0].id
        try state.importWebCourses([value], deadline: deadline, now: now)
        XCTAssertEqual(state.courses.count, 1)
        XCTAssertEqual(state.courses[0].id, id)
        XCTAssertEqual(state.courses[0].initialCompletedMinutes, 30)
        let course = state.courses[0]
        XCTAssertEqual(value.applying(to: course, loggedMinutes: 10)?.initialCompletedMinutes, 20)
        XCTAssertEqual(value.applying(to: course, loggedMinutes: 40)?.initialCompletedMinutes, 0)
        XCTAssertNil(value.applying(to: course, loggedMinutes: 70))
    }
    func testMissingDataAndPartialFetchBlockImport() {
        var value = snapshot()
        value.lessons[0].watchedPercent = nil
        XCTAssertNotNil(value.importProblem)
        value = snapshot(); value.lessons[0].durationSeconds = nil
        XCTAssertNotNil(value.importProblem)
        value = snapshot(); value.fetchedOutlines = 0
        XCTAssertNotNil(value.importProblem)
        value = snapshot(); value.lessons[0].watchedPercent = 101
        XCTAssertNotNil(value.importProblem)
    }
    func testOldCourseDecodingAndNewSnapshotRoundtrip() throws {
        var course = Course(name: "旧课", totalMinutes: 100, startDate: Date(), deadline: Date())
        let old = try JSONEncoder().encode(course)
        XCTAssertNil(try JSONDecoder().decode(Course.self, from: old).webCourse)
        XCTAssertNil(try JSONDecoder().decode(Course.self, from: old).manualLessons)
        XCTAssertNil(try JSONDecoder().decode(Course.self, from: old).lessonOrderCustomized)
        course.webCourse = snapshot()
        XCTAssertEqual(try JSONDecoder().decode(Course.self, from: JSONEncoder().encode(course)), course)
    }
    func testImportIsAtomicWhenOnePackageFails() {
        var state = PlannerState(), bad = snapshot()
        bad.packageID = "2"; bad.issues = ["网络失败"]
        XCTAssertThrowsError(try state.importWebCourses([snapshot(),bad], deadline: Date().addingTimeInterval(86400), now: Date()))
        XCTAssertTrue(state.courses.isEmpty)
    }
    func testReimportArchivedCourseRestoresSchedulingWithChosenDates() throws {
        let now = Date()
        let deadline = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        var old = Course(name: "旧课", totalMinutes: 61,
                         startDate: Calendar.current.date(byAdding: .day, value: -30, to: now)!,
                         deadline: Calendar.current.date(byAdding: .day, value: -1, to: now)!)
        old.webCourse = snapshot()
        old.isArchived = true
        old.autoScheduleEnabled = false
        var state = PlannerState()
        state.courses = [old]

        try state.importWebCourses([snapshot()], deadline: deadline, now: now)

        let restored = try XCTUnwrap(state.courses.first)
        XCTAssertEqual(restored.id, old.id)
        XCTAssertFalse(restored.isArchived)
        XCTAssertTrue(restored.autoScheduleEnabled)
        XCTAssertEqual(restored.startDate, now)
        XCTAssertEqual(restored.deadline, deadline)
        XCTAssertEqual(ScheduleEngine().generate(state: state, now: now).tasks.map(\.lessonID), ["1:1"])
    }
}
