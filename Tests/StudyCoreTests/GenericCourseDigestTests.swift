import XCTest
@testable import StudyCore

final class GenericCourseDigestTests: XCTestCase {
    private func digest(_ bodies: String..., pageTitle: String = "") -> [WebCourseSnapshot] {
        let responses = bodies.enumerated().map { index, body in
            CapturedResponse(url: "https://example.com/api/\(index)", body: body)
        }
        return GenericCourseDigest.snapshots(from: responses, pageURL: "https://example.com/my-course",
                                             pageTitle: pageTitle, now: Date(timeIntervalSince1970: 0))
    }

    func testNestedChaptersStayInOneCourse() throws {
        let snapshots = digest(#"""
        {"code":0,"data":{"courses":[{"course_id":11,"name":"高等数学","chapters":[
          {"name":"第一章","lessons":[{"id":1,"name":"1-1 极限","duration":1800,"progress":0.5},
                                      {"id":2,"name":"1-2 连续","duration":2400,"progress":1}]},
          {"name":"第二章","lessons":[{"id":3,"name":"2-1 导数","duration":3000,"progress":0.25}]}]}]}}
        """#)
        XCTAssertEqual(snapshots.count, 1)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.name, "高等数学")
        XCTAssertEqual(course.lessons.map(\.name), ["1-1 极限", "1-2 连续", "2-1 导数"])
        XCTAssertEqual(course.lessons.map(\.watchedPercent), [50, 100, 25])
        XCTAssertEqual(course.totalSeconds, 7200)
        XCTAssertEqual(course.packageID, "generic:高等数学")
        XCTAssertNil(course.importProblem)
    }

    func testSeparateListItemsBecomeSeparateCourses() throws {
        let snapshots = digest(#"""
        {"result":{"list":[{"id":"a","title":"数学","lessons":[{"id":1,"name":"L1","duration":600}]},
                           {"id":"b","title":"英语","lessons":[{"id":2,"name":"L2","duration":900}]}]}}
        """#)
        XCTAssertEqual(snapshots.map(\.name).sorted(), ["数学", "英语"])
        XCTAssertEqual(snapshots.first?.lessons.count, 1)
    }

    func testMillisecondDurationsAreScaledForTheWholeCourse() throws {
        let snapshots = digest(#"""
        {"data":[{"name":"课程A","sections":[{"id":1,"name":"S1","video_duration":3600000,"watched_percent":30},
                                             {"id":2,"name":"S2","video_duration":1800000,"watched_percent":0}]}]}
        """#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.map(\.durationSeconds), [3600, 1800])
        XCTAssertEqual(course.totalSeconds, 5400)
        XCTAssertEqual(course.lessons.first?.watchedPercent, 30)
    }

    func testSingleDigitPercentIsNotMistakenForARatio() throws {
        let snapshots = digest(#"""
        {"courses":[{"name":"C","lessons":[{"id":1,"name":"A","duration":100,"percent":1},
                                           {"id":2,"name":"B","duration":100,"percent":50}]}]}
        """#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.map(\.watchedPercent), [1, 50])
        XCTAssertEqual(course.watchedSeconds, 51)
    }

    func testPayloadsWithoutLessonEvidenceAreIgnored() {
        XCTAssertTrue(digest(#"{"user":{"name":"张三","age":30},"token":"abc"}"#).isEmpty)
        XCTAssertTrue(digest(#"{"courses":[{"name":"只有名字"}]}"#).isEmpty)
        XCTAssertTrue(digest("not json at all").isEmpty)
    }

    func testLessonWithoutDurationIsKeptOutOfTheTotal() throws {
        let snapshots = digest(#"""
        {"courses":[{"name":"C","lessons":[{"id":1,"name":"A","duration":600,"percent":0},
                                           {"id":2,"name":"待定直播","percent":0}]}]}
        """#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.count, 2)
        XCTAssertEqual(course.timedLessons.count, 1)
        XCTAssertEqual(course.totalSeconds, 600)
        XCTAssertEqual(course.unknownDurations, 0, "A lesson without a duration must not block the import")
        XCTAssertNil(course.importProblem)
    }

    func testPlayPositionBecomesProgress() throws {
        let snapshots = digest(#"""
        {"courses":[{"name":"C","lessons":[{"id":1,"name":"A","duration":600,"position":150}]}]}
        """#)
        XCTAssertEqual(try XCTUnwrap(snapshots.first).lessons.first?.watchedPercent, 25)
    }

    func testRepeatedLessonsAcrossResponsesAreMerged() throws {
        let snapshots = digest(#"""
        {"list":[{"id":1,"name":"数学","lessons":[{"id":1,"name":"L1","duration":600,"percent":0}]}]}
        """#, #"""
        {"detail":{"name":"数学","lessons":[{"id":1,"name":"L1","duration":600,"percent":0},
                                            {"id":2,"name":"L2","duration":600,"percent":50}]}}
        """#)
        XCTAssertEqual(snapshots.count, 1)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.count, 2)
        XCTAssertEqual(course.lessons.map(\.name), ["L1", "L2"])
        XCTAssertNil(course.importProblem)
    }

    func testCourseWithoutAnyDurationExplainsWhyItCannotBePlanned() throws {
        let snapshots = digest(#"{"courses":[{"name":"C","lessons":[{"name":"A","percent":50}]}]}"#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.count, 1)
        XCTAssertEqual(course.totalSeconds, 0)
        XCTAssertNotNil(course.importProblem)
    }

    func testSameNameInDifferentPayloadsKeepsOneStableIdentifier() throws {
        let first = digest(#"{"list":[{"id":7,"name":"政治","lessons":[{"id":1,"name":"L1","duration":600}]}]}"#)
        let second = digest(#"{"data":{"name":"政治","lessons":[{"id":1,"name":"L1","duration":600}]}}"#)
        XCTAssertEqual(try XCTUnwrap(first.first).packageID, try XCTUnwrap(second.first).packageID)
    }

    // MARK: Formatted values and course identity, as used by sites like ixuecheng.cn

    func testFormattedDurationsAndCourseIdKeepChaptersTogether() throws {
        let snapshots = digest(#"""
        {"code":0,"data":[
          {"id":"1","title":"第一章 函数与极限","type":"1","children":[
            {"id":"11","title":"1-1 函数","type":"3","videoDuration":"45:30","courseId":"88"},
            {"id":"12","title":"1-2 极限","type":"3","videoDuration":"1:02:03","courseId":"88"},
            {"id":"13","title":"章节测验","type":"4","courseId":"88"}]},
          {"id":"2","title":"第二章 导数","type":"1","children":[
            {"id":"21","title":"2-1 导数定义","type":"3","videoDuration":"52分钟","courseId":"88"}]}]}
        """#)
        XCTAssertEqual(snapshots.count, 1, "Chapters of one course must not become separate courses")
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.packageID, "generic:88")
        XCTAssertEqual(course.lessons.map(\.name), ["1-1 函数", "1-2 极限", "2-1 导数定义"])
        XCTAssertEqual(course.lessons.compactMap(\.durationSeconds), [2730, 3723, 3120])
        XCTAssertEqual(course.totalSeconds, 2730 + 3723 + 3120)
        XCTAssertEqual(course.name, "第一章 函数与极限")
        XCTAssertNil(course.importProblem)
    }

    func testPageTitleNamesACourseThatHasNoLabelAnywhere() throws {
        let snapshots = digest(#"""
        {"data":[{"id":"11","title":"1-1 函数","type":"3","videoDuration":"45:30","courseId":"88"}]}
        """#, pageTitle: "考研数学全程班")
        XCTAssertEqual(try XCTUnwrap(snapshots.first).name, "考研数学全程班")
    }

    func testNumericStringsStillFollowTheCourseWideUnit() throws {
        let snapshots = digest(#"""
        {"data":[{"title":"A","videoDuration":"2700","courseId":"9"},{"title":"B","videoDuration":"1800","courseId":"9"}]}
        """#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.totalSeconds, 4500)
        XCTAssertEqual(course.lessons.count, 2)
    }

    func testFormattedPercentStringsAreRead() throws {
        let snapshots = digest(#"""
        {"data":[{"title":"A","videoDuration":"10:00","schedule":"45%","courseId":"5"},
                 {"title":"B","videoDuration":"10:00","schedule":"0%","courseId":"5"}]}
        """#)
        let course = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(course.lessons.map(\.watchedPercent), [45, 0])
        XCTAssertEqual(course.watchedSeconds, 270)
    }
}
