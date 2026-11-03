import XCTest
import StudyCore
import StudyPersistence
@testable import StudyPlanner

final class WebsiteCourseUpdaterTests: XCTestCase {
    private final class Repository: PlannerRepository {
        var saved: PlannerState?
        var fails = false
        func load() throws -> PlannerState { saved ?? PlannerState() }
        func save(_ state: PlannerState) throws {
            if fails { throw CocoaError(.fileWriteUnknown) }
            saved = state
        }
    }
    private func snapshot(ids: [String] = ["1", "2"], progress: Double = 0) -> WebCourseSnapshot {
        WebCourseSnapshot(packageID: "42", name: "测试研途课程",
            sourceURL: "https://www.kaoyanvip.cn/appmanage/my/mycourse/delivery-packages/42/outline",
            fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
            lessons: ids.map { .init(id: "42:" + $0, name: "课节" + $0, subject: "数学", stage: "基础", chapter: "",
                                     kind: "video", published: true, durationSeconds: 3600, watchedPercent: progress,
                                     markedFinished: false, requiresDuration: true) }, issues: [])
    }
    @MainActor private func fixture() throws -> (PlannerStore, Repository, Course) {
        var state = PlannerState()
        state.settings.availability = []
        try state.importWebCourses([snapshot()], deadline: Date().addingTimeInterval(86400 * 7), now: Date())
        let repository = Repository()
        let store = PlannerStore(state: state, repository: repository, result: ScheduleEngine().generate(state: state, now: Date()))
        return (store, repository, state.courses[0])
    }
    func testOnlyExactSitesAndMatchingCourseURLsAreAccepted() throws {
        XCTAssertNil(CourseWebsite.identify(URL(string: "https://www.kaoyanvip.cn.evil.example")!))
        XCTAssertNil(CourseWebsite.identify(URL(string: "https://evil.ixuecheng.cn")!))
        XCTAssertNil(CourseWebsite.identify(URL(string: "http://ixuecheng.cn/detail?id=4")!))
        XCTAssertNil(CourseWebsite.identify(URL(string: "https://ixuecheng.cn:9443/detail?id=4")!))
        XCTAssertNoThrow(try CourseWebsite.yantu.courseURL(snapshot().sourceURL, packageID: "42"))
        XCTAssertThrowsError(try CourseWebsite.yantu.courseURL(snapshot().sourceURL, packageID: "41"))
        XCTAssertThrowsError(try CourseWebsite.yantu.courseURL(snapshot().sourceURL + "?token=PLACEHOLDER", packageID: "42"))
        XCTAssertNoThrow(try CourseWebsite.xuecheng.courseURL("ixuecheng.cn/detail?id=88&type=1", packageID: "generic:88"))
        XCTAssertThrowsError(try CourseWebsite.xuecheng.courseURL("ixuecheng.cn/detail?id=88&id=99", packageID: "generic:88"))
        XCTAssertThrowsError(try CourseWebsite.xuecheng.courseURL("ixuecheng.cn/detail?id=88&token=PLACEHOLDER", packageID: "generic:88"))
    }
    @MainActor func testAutomaticUpdateAppendsLessonsAndPreservesLatestLocalEditsAndOrder() async throws {
        let (store, _, course) = try fixture()
        var changed = course
        changed.lessonOrder = ["42:2", "42:1"]; changed.lessonOrderCustomized = true
        _ = await store.saveCourse(changed)
        let fresh = snapshot(ids: ["1", "2", "3"], progress: 10)
        let updater = WebsiteCourseUpdater { _, packageID, site, interactive in
            XCTAssertEqual(packageID, "42"); XCTAssertEqual(site, .yantu); XCTAssertFalse(interactive)
            var edited = try XCTUnwrap(store.course(course.id))
            edited.name = "本地修改的课程名"; edited.priority = 7
            _ = await store.saveCourse(edited)
            return fresh
        }
        updater.start(store: store)
        try updater.configure(course: changed, url: fresh.sourceURL, enabled: true, interval: 60)
        await updater.tick()
        let updated = try XCTUnwrap(store.course(course.id))
        XCTAssertEqual(updated.id, course.id)
        XCTAssertEqual(updated.priority, 7)
        XCTAssertEqual(updated.name, "本地修改的课程名")
        XCTAssertEqual(updated.deadline, course.deadline)
        XCTAssertEqual(store.state.lessonWorkItems(for: updated).map(\.id), ["42:2", "42:1", "42:3"])
        XCTAssertEqual(updated.webCourse?.lessons.count, 3)
        XCTAssertNotNil(updater.sources[course.id]?.lastSuccess)
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, false)
    }
    @MainActor func testIncompleteOrMissingLessonsPauseAndDoNotOverwriteOrRetry() async throws {
        for partial in [true, false] {
            let (store, repo, course) = try fixture()
            let before = store.state
            var fresh = snapshot(ids: partial ? ["1", "2"] : ["1"])
            if partial { fresh.fetchedOutlines = 0 }
            var calls = 0
            let updater = WebsiteCourseUpdater { _, _, _, _ in calls += 1; return fresh }
            updater.start(store: store)
            try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 30)
            await updater.tick()
            await updater.tick(now: Date().addingTimeInterval(86400))
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(store.state, before)
            XCTAssertNil(repo.saved)
            XCTAssertEqual(updater.sources[course.id]?.needsAttention, true)
        }
    }
    @MainActor func testDisableDuringFetchPreventsWrite() async throws {
        let (store, _, course) = try fixture()
        let before = store.state, fresh = snapshot(ids: ["1", "2", "3"])
        var updater: WebsiteCourseUpdater!
        updater = WebsiteCourseUpdater { _, _, _, _ in
            try updater.configure(course: course, url: fresh.sourceURL, enabled: false, interval: 60)
            return fresh
        }
        updater.start(store: store)
        try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 60)
        await updater.tick()
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(updater.sources[course.id]?.enabled, false)
    }
    @MainActor func testReplayTimeoutIsVisibleAndPausesWithoutChangingCourseOrRetrying() async throws {
        let (store, repo, course) = try fixture()
        let before = store.state
        let message = "直播回放读取超时，更新已暂停，原课程已保留。"
        var calls = 0
        let updater = WebsiteCourseUpdater { _, _, _, _ in
            calls += 1
            throw WebsiteUpdateError.message(message)
        }
        updater.start(store: store)
        defer { updater.stop() }
        try updater.configure(course: course, url: snapshot().sourceURL, enabled: true, interval: 30)
        await updater.tick()
        await updater.tick(now: Date().addingTimeInterval(86400))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(updater.sources[course.id]?.status, message)
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, true)
        XCTAssertEqual(store.state, before)
        XCTAssertNil(repo.saved)
    }

    @MainActor func testPendingLessonIsRetainedAndLaterPublishedWithoutPausingUpdates() async throws {
        let (store, _, course) = try fixture()
        var fresh = snapshot(ids: ["1", "2", "3"])
        fresh.lessons[2].published = false
        fresh.lessons[2].requiresDuration = false
        fresh.lessons[2].durationSeconds = nil
        var calls = 0
        let updater = WebsiteCourseUpdater { _, _, _, _ in calls += 1; return fresh }
        updater.start(store: store)
        defer { updater.stop() }
        try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 60)
        await updater.tick()
        let pending = try XCTUnwrap(store.course(course.id))
        XCTAssertEqual(pending.webCourse?.lessons.count, 3)
        XCTAssertEqual(pending.totalMinutes, course.totalMinutes)
        XCTAssertEqual(store.state.lessonWorkItems(for: pending).map(\.id), ["42:1", "42:2"])
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, false)
        XCTAssertTrue(updater.sources[course.id]?.status.contains("1 个课节尚未更新") == true)
        fresh = snapshot(ids: ["1", "2", "3"])
        await updater.tick(now: Date().addingTimeInterval(7200))
        let published = try XCTUnwrap(store.course(course.id))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(published.totalMinutes, course.totalMinutes + 60)
        XCTAssertEqual(store.state.lessonWorkItems(for: published).map(\.id), ["42:1", "42:2", "42:3"])
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, false)
        XCTAssertEqual(updater.sources[course.id]?.status, "更新成功")
    }
    @MainActor func testDeletedCourseDuringFetchIsNotRecreated() async throws {
        let (store, _, course) = try fixture()
        let fresh = snapshot()
        let updater = WebsiteCourseUpdater { _, _, _, _ in
            _ = await store.deleteCourse(course)
            return fresh
        }
        updater.start(store: store)
        try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 60)
        await updater.tick()
        XCTAssertTrue(store.courses.isEmpty)
        XCTAssertNil(updater.sources[course.id]?.lastSuccess)
    }
    @MainActor func testSaveFailurePreservesOldStateAndPauses() async throws {
        let (store, repo, course) = try fixture()
        let before = store.state, fresh = snapshot(progress: 50)
        repo.fails = true
        let updater = WebsiteCourseUpdater { _, _, _, _ in fresh }
        updater.start(store: store)
        await updater.update(courseID: course.id)
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, true)
        XCTAssertNil(updater.sources[course.id]?.lastSuccess)
    }
    @MainActor func testOpenEditorDefersFetchUntilClosedAndIntervalIsRespected() async throws {
        let (store, _, course) = try fixture()
        let fresh = snapshot()
        var calls = 0
        let updater = WebsiteCourseUpdater { _, _, _, _ in calls += 1; return fresh }
        updater.start(store: store)
        try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 60)
        updater.beginEditing(course.id); updater.beginEditing(course.id)
        await updater.tick()
        updater.endEditing(course.id)
        await updater.tick()
        XCTAssertEqual(calls, 0)
        updater.endEditing(course.id)
        await updater.tick()
        await updater.tick()
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testLocalSettingsPersistButAreAbsentFromSyncedState() throws {
        let (store, _, course) = try fixture()
        let suite = "WebsiteCourseUpdaterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = WebsiteCourseUpdater(defaults: defaults)
        try updater.configure(course: course, url: snapshot().sourceURL, enabled: true, interval: 180)
        let restored = WebsiteCourseUpdater(defaults: defaults)
        XCTAssertEqual(restored.sources, updater.sources)
        let state = String(decoding: try JSONEncoder().encode(store.state), as: UTF8.self)
        XCTAssertFalse(state.contains("intervalMinutes"))
        XCTAssertFalse(state.contains("needsAttention"))
        XCTAssertFalse(state.contains("password"))
    }
    @MainActor func testEarlierSnapshotCannotReplaceNewerSyncedData() throws {
        let (_, _, course) = try fixture()
        var older = snapshot()
        older.fetchedAt = course.webCourse!.fetchedAt.addingTimeInterval(-60)
        XCTAssertThrowsError(try WebsiteCourseUpdater.validate(older, replacing: course))
    }
    @MainActor func testCancellationDoesNotLeaveAutomaticUpdatePermanentlyPaused() async throws {
        let (store, _, course) = try fixture()
        let before = store.state
        let updater = WebsiteCourseUpdater { _, _, _, _ in throw CancellationError() }
        updater.start(store: store)
        try updater.configure(course: course, url: snapshot().sourceURL, enabled: true, interval: 60)
        await updater.tick()
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(updater.sources[course.id]?.needsAttention, false)
        XCTAssertNil(updater.sources[course.id]?.lastAttempt)
    }
    @MainActor func testFailedLoginPausesSameWebsiteAndSuccessfulRetryResumesIt() async throws {
        let (store, _, first) = try fixture()
        var secondSnapshot = snapshot()
        secondSnapshot.packageID = "43"
        secondSnapshot.sourceURL = secondSnapshot.sourceURL.replacingOccurrences(of: "/42/", with: "/43/")
        _ = await store.change { state in
            try state.importWebCourses([secondSnapshot], deadline: first.deadline, now: Date())
        }
        let second = try XCTUnwrap(store.courses.first { $0.id != first.id })
        var calls = 0, succeed = false
        let fresh = snapshot()
        let updater = WebsiteCourseUpdater { _, _, _, _ in
            calls += 1
            if !succeed { throw WebsiteUpdateError.loginRequired }
            return fresh
        }
        updater.start(store: store)
        try updater.configure(course: first, url: fresh.sourceURL, enabled: true, interval: 60)
        try updater.configure(course: second, url: secondSnapshot.sourceURL, enabled: true, interval: 60)
        await updater.update(courseID: first.id)
        await updater.tick(now: Date().addingTimeInterval(86400))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(updater.sources[second.id]?.needsAttention, true)
        succeed = true
        await updater.update(courseID: first.id)
        XCTAssertEqual(updater.sources[second.id]?.needsAttention, false)
        XCTAssertNil(updater.sources[second.id]?.lastAttempt)
    }
    @MainActor func testDeletedLessonIsNotRestoredAndLocalConfirmationsSurvive() async throws {
        let (store, _, course) = try fixture()
        let task = ScheduledTask(courseID: course.id, start: Date().addingTimeInterval(-7200), durationMinutes: 20, lessonID: "42:1")
        _ = await store.change { state in
            state.tasks.append(task)
            try state.confirm(taskID: task.id, actualMinutes: 20, now: Date())
            try state.removeLessons(courseID: course.id, ids: ["42:2"])
        }
        let confirmations = store.state.completions
        let fresh = snapshot(ids: ["1", "2", "3"])
        let updater = WebsiteCourseUpdater { _, _, _, _ in fresh }
        updater.start(store: store)
        await updater.update(courseID: course.id)
        XCTAssertEqual(store.state.completions, confirmations)
        XCTAssertEqual(store.course(course.id)?.webCourse?.lessons.map(\.id), ["42:1", "42:3"])
    }

    @MainActor func testWebsiteRefreshPreservesSchedulingModeChosenDuringFetch() async throws {
        let (store, _, course) = try fixture()
        let fresh = snapshot(ids: ["1", "2", "3"])
        let updater = WebsiteCourseUpdater { _, _, _, _ in
            var edited = try XCTUnwrap(store.course(course.id))
            edited.type = .recorded
            edited.minimumBlockMinutes = 25
            let saved = await store.saveCourse(edited)
            XCTAssertTrue(saved)
            return fresh
        }
        updater.start(store: store)
        try updater.configure(course: course, url: fresh.sourceURL, enabled: true, interval: 60)
        await updater.tick()
        let updated = try XCTUnwrap(store.course(course.id))
        XCTAssertEqual(updated.type, .recorded)
        XCTAssertEqual(updated.minimumBlockMinutes, 25)
        XCTAssertEqual(updated.webCourse?.lessons.count, 3)
        XCTAssertNotNil(updater.sources[course.id]?.lastSuccess)
    }
}
