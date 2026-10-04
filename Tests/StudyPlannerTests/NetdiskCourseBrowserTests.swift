import XCTest
@testable import StudyCore
@testable import StudyPlanner

final class NetdiskCourseBrowserTests: XCTestCase {
    private func course(_ id: String, name: String, lesson: String = "第一讲", refusal: String? = nil)
        -> NetdiskSnapshotBuilder.Course {
        let snapshot = WebCourseSnapshot(packageID: id, name: name, sourceURL: "https://pan.quark.cn/s/example",
                                         fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                                         lessons: [WebCourseLesson(id: id + ":1", name: lesson, subject: "", stage: "",
                                                                   chapter: "", kind: "video", published: true,
                                                                   durationSeconds: 600, watchedPercent: 0,
                                                                   markedFinished: false, requiresDuration: true)],
                                         issues: [])
        return NetdiskSnapshotBuilder.Course(snapshot: snapshot, lessons: [:], refusal: refusal,
                                             packageID: id, name: name, videoCount: 1,
                                             estimatedLessons: 0, totalBytes: 100, detection: "", notes: [])
    }

    func testSearchFindsCourseFolderAndLessonWithoutChangingGlobalSelectionScope() {
        let courses = [course("math", name: "基础班", lesson: "微积分"),
                       course("english", name: "阅读课", lesson: "长难句"),
                       course("blocked", name: "旧课", refusal: "缺少时长")]
        let browser = NetdiskCourseBrowser(courses: courses,
                                           paths: ["math": "资料/数学/基础班", "english": "资料/英语/阅读课",
                                                   "blocked": "资料/数学/旧课"])
        XCTAssertEqual(browser.matching("微积分").map(\.packageID), ["math"])
        XCTAssertEqual(browser.matching("英语 阅读").map(\.packageID), ["english"])
        XCTAssertEqual(browser.matching("不存在").count, 0)
        XCTAssertEqual(browser.selectableIDs, ["math", "english"])
    }

    func testFolderGroupSelectsDescendantsAndSkipsRefusedCourses() throws {
        let courses = [course("math", name: "高数"), course("math2", name: "线代"),
                       course("english", name: "阅读"),
                       course("blocked", name: "损坏课程", refusal: "缺少时长")]
        let browser = NetdiskCourseBrowser(courses: courses,
                                           paths: ["math": "课程/数学/高数", "math2": "课程/数学/线代",
                                                   "english": "课程/英语/阅读", "blocked": "课程/数学/损坏课程"])
        let root = browser.grouped(courses)
        XCTAssertEqual(Set(root.children.map(\.title)), ["数学", "英语"])
        let math = try XCTUnwrap(root.children.first { $0.title == "数学" })
        XCTAssertEqual(math.count, 3)
        XCTAssertEqual(math.selectableIDs, ["math", "math2"])
        XCTAssertEqual(root.selectableIDs, browser.selectableIDs)
    }

    func testLocationOpensFullDirectoryAncestorsAfterSearchCompactsThem() {
        let courses = [course("math", name: "高数", lesson: "微积分"),
                       course("algebra", name: "线代"), course("advanced", name: "强化"),
                       course("english", name: "阅读")]
        let browser = NetdiskCourseBrowser(courses: courses,
            paths: ["math": "资料/数学/基础/高数", "algebra": "资料/数学/基础/线代",
                    "advanced": "资料/数学/强化", "english": "资料/英语/阅读"])
        let matches = browser.matching("微积分")
        // Filtering hides the ancestors; navigation must use the full tree instead.
        XCTAssertEqual(browser.grouped(matches).ancestorPaths(containing: "math"), ["资料/数学/基础"])
        let fullDirectory = browser.grouped(courses)
        XCTAssertEqual(fullDirectory.ancestorPaths(containing: "math"), ["资料/数学", "资料/数学/基础"])
        XCTAssertEqual(fullDirectory.selectableIDs, ["math", "algebra", "advanced", "english"])
    }

    func testLocationUsesPackageIDForSameNamedCoursesAndCompactedFolders() {
        let courses = [course("first", name: "基础班"), course("second", name: "基础班")]
        let browser = NetdiskCourseBrowser(courses: courses,
            paths: ["first": "课程/数学/视频/基础班", "second": "课程/数学提高/基础班"])
        let directory = browser.grouped(courses)
        XCTAssertEqual(directory.ancestorPaths(containing: "first"), ["课程/数学/视频"])
        XCTAssertEqual(directory.ancestorPaths(containing: "second"), ["课程/数学提高"])
        XCTAssertNil(directory.ancestorPaths(containing: "missing"))
    }

    func testLocationSupportsRootCoursesAndRefusedCandidates() {
        let courses = [course("root", name: "根目录课"),
                       course("blocked", name: "旧课", refusal: "缺少时长")]
        let browser = NetdiskCourseBrowser(courses: courses, paths: ["blocked": "数学/旧课"])
        let directory = browser.grouped(courses)
        XCTAssertEqual(directory.ancestorPaths(containing: "root"), [])
        XCTAssertEqual(directory.ancestorPaths(containing: "blocked"), ["数学"])
        XCTAssertEqual(directory.selectableIDs, ["root"])
    }
}
