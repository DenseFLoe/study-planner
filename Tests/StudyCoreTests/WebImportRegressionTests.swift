import XCTest
@testable import StudyCore

final class WebImportRegressionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func snapshot(host: String = "a.example", seconds: Int = 3600) throws -> WebCourseSnapshot {
        try XCTUnwrap(GenericCourseDigest.snapshots(from: [.init(url: "https://\(host)/api?token=SYNTHETIC_CREDENTIAL",
            body: "{\"data\":[{\"id\":\"L1\",\"courseId\":\"88\",\"name\":\"Course\",\"duration\":\(seconds),\"percent\":0}]}")],
            pageURL: "https://\(host)/course?session=SYNTHETIC_CREDENTIAL", now: now).first)
    }

    func testSharedPercentageAndDuplicateFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/web-import-regressions.json")
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for fixture in fixtures {
            let name = try XCTUnwrap(fixture["name"] as? String)
            let bodies = try XCTUnwrap(fixture["bodies"] as? [[String: Any]])
            let responses = try bodies.map { CapturedResponse(url: "https://a.example/api",
                body: String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)) }
            let value = try XCTUnwrap(GenericCourseDigest.snapshots(from: responses, pageURL: "https://a.example/course", now: now).first)
            XCTAssertEqual(value.lessons.map { $0.watchedPercent ?? -1 }, fixture["percent"] as? [Double], name)
            XCTAssertEqual(value.lessons.map { $0.durationSeconds ?? 0 }, fixture["seconds"] as? [Double], name)
            XCTAssertEqual(value.importProblem == nil, fixture["valid"] as? Bool, name)
            var state = PlannerState()
            if value.importProblem != nil {
                XCTAssertThrowsError(try state.importWebCourses([value], deadline: now, now: now), name)
                XCTAssertTrue(state.courses.isEmpty)
                continue
            }
            try state.importWebCourses([value], deadline: now, now: now)
            let course = try XCTUnwrap(state.courses.first)
            XCTAssertEqual(course.totalMinutes, fixture["totalMinutes"] as? Int, name)
            XCTAssertEqual(state.completedMinutes(for: course), fixture["completedMinutes"] as? Int, name)
            let work = state.lessonWorkItems(for: course)
            XCTAssertEqual(work.count, fixture["workItems"] as? Int, name)
            XCTAssertEqual(work.reduce(0) { $0 + $1.remainingMinutes }, value.remainingMinutes, name)
        }
    }

    func testCrossSiteImportsAndLegacyRefreshKeepHistoryAndDeletionIdentity() throws {
        let a = try snapshot(), b = try snapshot(host: "b.example", seconds: 7200)
        XCTAssertEqual(a.packageID, b.packageID, "Provider IDs remain compatible with existing data")
        XCTAssertNotEqual(a.identityKey, b.identityKey)
        var batch = PlannerState()
        try batch.importWebCourses([a, b], deadline: now, now: now)
        XCTAssertEqual(batch.courses.count, 2)
        var state = PlannerState()
        try state.importWebCourses([a], deadline: now, now: now)
        let courseID = state.courses[0].id
        let task = ScheduledTask(courseID: courseID, start: now, durationMinutes: 60, lessonID: a.lessons[0].id)
        state.tasks = [task]
        try state.confirm(taskID: task.id, actualMinutes: 60, now: now)
        state.courses[0].lessonOrderCustomized = true
        state.courses[0].deletedLessonIDs = ["generic:88:deleted"]
        try state.importWebCourses([b], deadline: now, now: now)
        XCTAssertEqual(state.courses.count, 2)
        XCTAssertEqual(state.completedMinutes(for: state.courses[1]), 0)
        XCTAssertEqual(state.remainingMinutes(for: state.courses[1]), 120)
        XCTAssertNil(state.courses[1].deletedLessonIDs)
        XCTAssertEqual(try a.matchingCourseIndices(in: state.courses), [0])
        XCTAssertEqual(try b.matchingCourseIndices(in: state.courses), [1])
        var refreshed = a
        refreshed.sourceURL = "https://A.EXAMPLE:443/new-page?token=SYNTHETIC_CREDENTIAL"
        refreshed.lessons.append(.init(id: "generic:88:deleted", name: "Deleted", subject: "", stage: "", chapter: "",
            kind: "video", published: true, durationSeconds: 3600, watchedPercent: 0, markedFinished: false, requiresDuration: true))
        try state.importWebCourses([refreshed], deadline: now, now: now)
        XCTAssertEqual(state.courses.count, 2)
        XCTAssertEqual(state.courses[0].id, courseID)
        XCTAssertEqual(state.courses[0].webCourse?.lessons.map(\.id), a.lessons.map(\.id))
        XCTAssertEqual(state.courses[0].lessonOrderCustomized, true)
        XCTAssertEqual(state.completedMinutes(for: state.courses[0]), 60)
        XCTAssertEqual(state.completions.count, 1)
        var ledger = SyncLedger(); try ledger.capture(state)
        var peer = SyncLedger(); try peer.merge(ledger.changes(after: 0))
        let restored = try peer.materialize()
        XCTAssertEqual(restored.courses.count, 2)
        XCTAssertEqual(Set(restored.courses.map(\.id)), Set(state.courses.map(\.id)))
        XCTAssertEqual(restored.completions, state.completions)
    }

    func testUnknownLegacySourceAndAmbiguousSameSiteRefuseAtomically() throws {
        let a = try snapshot()
        for ambiguous in [false, true] {
            var state = PlannerState()
            try state.importWebCourses([a], deadline: now, now: now)
            if ambiguous { var duplicate = state.courses[0]; duplicate.id = UUID(); state.courses.append(duplicate) }
            else { state.courses[0].webCourse?.sourceURL = "" }
            let before = state
            XCTAssertThrowsError(try state.importWebCourses([snapshot(host: "other.example"), a], deadline: now, now: now))
            XCTAssertEqual(state, before)
        }
    }

    func testSafeURLRemovesAuthenticationAndKeepsPublicXuechengLocator() throws {
        let privateURL = "https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@ixuecheng.cn/detail?id=88&type=1&token=SYNTHETIC_CREDENTIAL&session=SYNTHETIC_SESSION#SYNTHETIC_FRAGMENT"
        XCTAssertEqual(WebCourseIdentity.safeURL(privateURL), "https://ixuecheng.cn/detail?id=88&type=1")
        XCTAssertEqual(WebCourseIdentity.safeURL("https://other.example/detail?id=88&session=SYNTHETIC_SESSION#SYNTHETIC_FRAGMENT"), "https://other.example/detail")
        var value = try snapshot()
        value.sourceURL = privateURL
        XCTAssertEqual(value.sourceURL, "https://ixuecheng.cn/detail?id=88&type=1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object["sourceURL"] = privateURL
        let legacy = try JSONDecoder().decode(WebCourseSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy, value)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("SYNTHETIC_"))
        XCTAssertEqual(try snapshot().sourceURL, "https://a.example/course", "Prefer the course page over the captured API URL")
    }
}
