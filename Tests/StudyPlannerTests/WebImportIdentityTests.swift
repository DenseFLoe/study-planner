import XCTest
import StudyCore
@testable import StudyPlanner

final class WebImportIdentityTests: XCTestCase {
    @MainActor
    func testCaptureMergeAndPreviewUseSiteIdentity() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func capture(_ host: String, _ duration: Int) throws -> WebCourseSnapshot {
            try XCTUnwrap(GenericCourseDigest.snapshots(from: [.init(url: "https://\(host)/api",
                body: "{\"data\":[{\"id\":\"L1\",\"courseId\":\"88\",\"name\":\"L1\",\"duration\":\(duration),\"percent\":0}]}")],
                pageURL: "https://\(host)/course", now: now).first)
        }
        let a = try capture("a.example", 3600), b = try capture("b.example", 7200)
        let values = WebLessonReader.merged([a], with: [b])
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(Set(values.map(\.identityKey)).count, 2, "Each card/selection has a distinct identity")
        var preview = PlannerState()
        try preview.importWebCourses(values, deadline: now, now: now)
        XCTAssertEqual(try a.matchingCourseIndices(in: preview.courses), [0])
        XCTAssertEqual(try b.matchingCourseIndices(in: preview.courses), [1])
        XCTAssertEqual(WebLessonReader.merged(values, with: [a]).count, 2)
        let thin = try capture("a.example", 0)
        let merged = try XCTUnwrap(WebLessonReader.merged([a], with: [thin]).first)
        XCTAssertEqual(merged.timedLessons.count, 1)
        XCTAssertEqual(merged.totalMinutes, 60)
        XCTAssertNil(merged.importProblem)
    }

    @MainActor
    func testXuechengLocatorSurvivesSanitizationAndWWWRedirect() throws {
        let now = Date()
        let lesson = WebCourseLesson(id: "generic:88:L1", name: "L1", subject: "", stage: "", chapter: "",
            kind: "video", published: true, durationSeconds: 3600, watchedPercent: 0, markedFinished: false, requiresDuration: true)
        let old = WebCourseSnapshot(packageID: "generic:88", name: "Course",
            sourceURL: "https://ixuecheng.cn/detail?id=88&type=1&access_token=SYNTHETIC_TOKEN", fetchedAt: now,
            expectedOutlines: 1, fetchedOutlines: 1, lessons: [lesson], issues: [])
        XCTAssertNoThrow(try CourseWebsite.xuecheng.courseURL(old.sourceURL, packageID: old.packageID))
        var state = PlannerState(); try state.importWebCourses([old], deadline: now, now: now)
        var fresh = old; fresh.sourceURL = "https://www.ixuecheng.cn/detail?id=88&type=1"
        XCTAssertNoThrow(try WebsiteCourseUpdater.validate(fresh, replacing: state.courses[0]))
        XCTAssertEqual(WebLessonReader.merged([old], with: [fresh]).count, 1)
        fresh.sourceURL = "https://another.example/course"
        XCTAssertThrowsError(try WebsiteCourseUpdater.validate(fresh, replacing: state.courses[0]))
    }
}
