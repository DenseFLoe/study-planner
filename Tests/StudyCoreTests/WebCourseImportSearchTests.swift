import XCTest
@testable import StudyCore

final class WebCourseImportSearchTests: XCTestCase {
    private func snapshot(_ name: String = "数学课程", host: String = "example.test",
                          id: String = "course1", lessonName: String = "极限 Algebra",
                          subject: String = "数学二", stage: String = "基础", chapter: String = "第一章") -> WebCourseSnapshot {
        let lesson = WebCourseLesson(id: "opaque-lesson", name: lessonName, subject: subject, stage: stage,
                                     chapter: chapter, kind: "video", published: true, durationSeconds: 600,
                                     watchedPercent: 25, markedFinished: false, requiresDuration: true)
        return WebCourseSnapshot(packageID: "generic:" + id, name: name, sourceURL: "https://" + host + "/course",
                                 fetchedAt: Date(timeIntervalSince1970: 1_790_000_000), expectedOutlines: 1,
                                 fetchedOutlines: 1, lessons: [lesson], issues: [])
    }

    func testBlankQueryIncludesEveryCourseWithoutChangingIdentity() {
        let courses = [snapshot(), snapshot("英语", host: "other.test")]
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: " \n\t", snapshots: courses), Set(courses.map(\.identityKey)))
        XCTAssertTrue(WebCourseImportSearch.matchingIDs(query: "math", snapshots: []).isEmpty)
    }

    func testCombinedTermsCanMatchDifferentVisibleFields() {
        let course = snapshot()
        for query in ["数学 极限", "数学二 基础 第一章", "example.test Algebra", "ＡＬＧＥＢＲＡ　数学二"] {
            XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: query, snapshots: [course]), [course.identityKey], query)
        }
        XCTAssertTrue(WebCourseImportSearch.matchingIDs(query: "极限 冲刺", snapshots: [course]).isEmpty)
    }

    func testIdenticalNamesAndProviderIDsRemainSeparatedByWebsite() {
        let a = snapshot("同名课程", host: "alpha.test"), b = snapshot("同名课程", host: "beta.test")
        XCTAssertNotEqual(a.identityKey, b.identityKey)
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "同名课程", snapshots: [a, b]), [a.identityKey, b.identityKey])
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "BETA.TEST", snapshots: [a, b]), [b.identityKey])
    }

    func testPrivateURLComponentsAndOpaqueIDsAreNotSearchable() {
        var course = snapshot(id: "SYNTHETIC_PRIVATE_ID")
        course.lessons[0].id = "SYNTHETIC_PRIVATE_LESSON"
        course.sourceURL = "https://person:SYNTHETIC_PASSWORD@example.test/private-path?token=private-token#private-fragment"
        for query in ["SYNTHETIC", "person", "private-path", "private-token", "private-fragment"] {
            XCTAssertTrue(WebCourseImportSearch.matchingIDs(query: query, snapshots: [course]).isEmpty, query)
        }
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "example.test", snapshots: [course]), [course.identityKey])
        XCTAssertEqual(WebCourseImportSearch.websiteLabel(for: course), "example.test")
    }

    func testDifferentWebsitePortsCanBeDistinguishedWithoutDisplayingCredentials() {
        let a = snapshot(host: "example.test:8443"), b = snapshot(host: "example.test:9443")
        XCTAssertEqual(WebCourseImportSearch.websiteLabel(for: a), "example.test:8443")
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "8443", snapshots: [a, b]), [a.identityKey])
        XCTAssertEqual(WebCourseImportSearch.websiteLabel(for: snapshot(host: "example.test:443")), "example.test")
    }

    func testRefreshKeepsDeselectionAndRemovesUnavailableChoices() {
        XCTAssertEqual(WebCourseImportSelection.refreshed(selected: [], previouslyOffered: [], offered: ["a", "b"]), ["a", "b"])
        XCTAssertEqual(WebCourseImportSelection.refreshed(selected: ["a"], previouslyOffered: ["a", "b"], offered: ["a", "b", "c"]), ["a", "c"])
        XCTAssertEqual(WebCourseImportSelection.refreshed(selected: ["a", "c"], previouslyOffered: ["a", "b", "c"], offered: ["b", "c"]), ["c"])
        XCTAssertEqual(WebCourseImportSelection.refreshed(selected: [], previouslyOffered: ["a", "b"], offered: ["a", "b"]), [])
    }

    func testIncompleteCoursesStayVisibleForReview() {
        var incomplete = snapshot("待核对课程")
        incomplete.fetchedOutlines = 0
        incomplete.issues = ["目录未完成"]
        XCTAssertNotNil(incomplete.importProblem)
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "待核对", snapshots: [incomplete]), [incomplete.identityKey])
    }

    func testLargeCatalogFindsLessonMetadataWithoutBroadeningTheSelection() {
        let courses = (0..<250).map { index -> WebCourseSnapshot in
            var course = snapshot("课程\(index)", id: String(index))
            course.lessons = (0..<20).map { lessonIndex in
                var lesson = course.lessons[0]
                lesson.id = "\(index)-\(lessonIndex)"
                lesson.name = "第\(lessonIndex)讲"
                lesson.chapter = index == 137 && lessonIndex == 19 ? "目标章节" : "普通章节"
                return lesson
            }
            return course
        }
        XCTAssertEqual(WebCourseImportSearch.matchingIDs(query: "课程１３７ 目标章节", snapshots: courses), [courses[137].identityKey])
        XCTAssertTrue(WebCourseImportSearch.matchingIDs(query: "课程138 目标章节", snapshots: courses).isEmpty)
    }
}
