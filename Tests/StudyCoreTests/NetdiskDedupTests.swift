import XCTest
@testable import StudyCore

/// Covers the duplicate detection: copies inside one course, the same course under two folders,
/// and a course that is already in the plan.
final class NetdiskDedupTests: XCTestCase {

    private func package(_ entries: [NetdiskEntry], path: String) throws -> NetdiskPackage {
        let outcome = NetdiskFixtures.digest(entries)
        return try XCTUnwrap(outcome.packages.first { $0.path == path },
                             "expected a course at \(path), got \(outcome.packages.map(\.path))")
    }

    // MARK: - 课内副本

    func testExactCopyIsRemovedAndBestQualityKept() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", size: 100_000_000,
                                             duration: 900, width: 1280, height: 720, fid: "low"))
        entries.append(NetdiskFixtures.video("第3讲 极限 (1).mp4", in: "课程", size: 100_000_000,
                                             duration: 900, width: 1280, height: 720, fid: "copy"))
        entries.append(NetdiskFixtures.video("第3讲 极限 1080p.mp4", in: "课程", size: 300_000_000,
                                             duration: 900, width: 1920, height: 1080, fid: "best"))
        let course = try package(entries, path: "课程")
        let report = NetdiskDedup.scan(packages: [course])
        let group = try XCTUnwrap(report.withinCourses.first)
        XCTAssertEqual(group.retained.fid, "best", "同样时长时保留清晰度最高的一份")
        XCTAssertEqual(Set(group.removed.map(\.fid)), ["low", "copy"])
        // 720p 与 1080p 字节数差三倍，属于"同一节课的不同版本"，要让人确认而不是自动丢。
        XCTAssertTrue(group.requiresReview)
        XCTAssertEqual(group.removed.count, 2)
        XCTAssertEqual(report.removedVideoCount, 2)
    }

    func testIdenticalLessonWithDifferentBytesNeedsReview() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", size: 100_000_000, fid: "a"))
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", size: 150_000_000, fid: "b"))
        let course = try package(entries, path: "课程")
        let report = NetdiskDedup.scan(packages: [course])
        let group = try XCTUnwrap(report.withinCourses.first)
        XCTAssertEqual(group.retained.fid, "b", "体积大的那份先保留")
        XCTAssertTrue(group.requiresReview, "字节数差一半，必须让人确认")
        XCTAssertEqual(report.reviewCount, 1)
    }

    func testSafeCopiesAreOmittedFromImportPackage() throws {
        let entries = [NetdiskFixtures.folder("课程"),
                       NetdiskFixtures.video("第1讲 极限.mp4", in: "课程", size: 100_000_000,
                                             duration: 900, fid: "first"),
                       NetdiskFixtures.video("第1讲 极限 (1).mp4", in: "课程", size: 100_000_000,
                                             duration: 900, fid: "copy"),
                       NetdiskFixtures.video("第2讲 导数.mp4", in: "课程", size: 100_000_000,
                                             duration: 900, fid: "other")]
        let course = try package(entries, path: "课程")
        let report = NetdiskDedup.scan(packages: [course])
        let imported = NetdiskDedup.removingSafeCopies(from: course, report: report)
        XCTAssertEqual(imported.videoCount, 2)
        XCTAssertTrue(imported.videos.contains { $0.fid == "other" })
        XCTAssertEqual(imported.totalBytes, 200_000_000)
    }

    func testDifferentEpisodesOrTopicsAreNotDuplicates() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", fid: "e3"))
        entries.append(NetdiskFixtures.video("第4讲 极限.mp4", in: "课程", fid: "e4"))
        entries.append(NetdiskFixtures.video("第3讲 连续.mp4", in: "课程", fid: "e3b"))
        let course = try package(entries, path: "课程")
        let report = NetdiskDedup.scan(packages: [course])
        XCTAssertTrue(report.withinCourses.isEmpty, "集数或主题不同就不是副本")
    }

    func testPreviewFragmentIsNotTreatedAsACopy() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", size: 100_000_000,
                                             duration: 900, fid: "full"))
        // A three-second fragment under the same name is a preview, not a copy of the lesson.
        entries.append(NetdiskFixtures.video("第3讲 极限.mp4", in: "课程", size: 500_000,
                                             duration: 3, fid: "clip"))
        let course = try package(entries, path: "课程")
        let report = NetdiskDedup.scan(packages: [course])
        XCTAssertTrue(report.withinCourses.isEmpty)
    }

    // MARK: - 跨课程重复

    /// Two folders holding the same lessons, one lesson longer per `extraLesson`.
    private func twinPackages(_ encodeSuffix: String, extraLesson: Bool = false) -> [NetdiskPackage] {
        var entries: [NetdiskEntry] = [NetdiskFixtures.folder("A"), NetdiskFixtures.folder("B")]
        let titles = ["第1讲 函数", "第2讲 极限", "第3讲 导数", "第4讲 积分"]
        for title in titles {
            entries.append(NetdiskFixtures.video(title + encodeSuffix + ".mp4", in: "A",
                                                 size: 200_000_000, duration: 600))
            entries.append(NetdiskFixtures.video(title + encodeSuffix + ".mp4", in: "B",
                                                 size: 210_000_000, duration: 600))
        }
        if extraLesson {
            entries.append(NetdiskFixtures.video("第5讲 微分方程.mp4", in: "B", size: 200_000_000, duration: 600))
        }
        return NetdiskFixtures.digest(entries).packages
    }

    func testSameCourseInTwoFoldersIsDetectedAndDropped() throws {
        let packages = twinPackages(" 1080p")
        XCTAssertEqual(packages.count, 2)
        let report = NetdiskDedup.scan(packages: packages)
        XCTAssertEqual(report.droppedPackages.count, 1, "同一门课的两份只应自动去掉一份")
        let duplicate = try XCTUnwrap(report.droppedPackages.first)
        XCTAssertGreaterThan(duplicate.overlapRatio, 0.99)
        XCTAssertFalse(duplicate.requiresReview, "完全相同的课节集合应自动处理")
        XCTAssertEqual(NetdiskDedup.applied(packages, report: report).count, 1)
    }

    func testNearIdenticalCoursesAreListedForADecision() throws {
        let packages = twinPackages("", extraLesson: true)
        let report = NetdiskDedup.scan(packages: packages)
        let duplicate = try XCTUnwrap(report.droppedPackages.first)
        XCTAssertTrue(duplicate.requiresReview, "一节之差只提示，不自动丢")
        XCTAssertEqual(NetdiskDedup.applied(packages, report: report).count, 2, "待确认的课程保持可导入")
        XCTAssertEqual(report.reviewCount, 1)
    }

    func testDifferentCoursesAreNotFlagged() throws {
        var entries: [NetdiskEntry] = [NetdiskFixtures.folder("高数"), NetdiskFixtures.folder("线代")]
        for index in 1...4 {
            entries.append(NetdiskFixtures.video("第\(index)讲 高数强化.mp4", in: "高数", duration: 600))
            entries.append(NetdiskFixtures.video("第\(index)讲 线性代数.mp4", in: "线代", duration: 900))
        }
        let packages = NetdiskFixtures.digest(entries).packages
        let report = NetdiskDedup.scan(packages: packages)
        XCTAssertTrue(report.droppedPackages.isEmpty)
    }

    func testGenericLessonNumbersDoNotMakeDifferentCoursesDuplicates() {
        var entries = [NetdiskFixtures.folder("高数测评"), NetdiskFixtures.folder("线代测评")]
        for index in 1...4 {
            entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "高数测评", duration: 600))
            entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "线代测评", duration: 600))
        }
        let report = NetdiskDedup.scan(packages: NetdiskFixtures.digest(entries).packages)
        XCTAssertTrue(report.droppedPackages.isEmpty)
    }

    func testSubsetIsNotAutoMerged() throws {
        var entries: [NetdiskEntry] = [NetdiskFixtures.folder("全量"), NetdiskFixtures.folder("试看")]
        for index in 1...8 {
            entries.append(NetdiskFixtures.video("第\(index)讲 高数强化.mp4", in: "全量", duration: 600))
        }
        for index in 1...2 {
            entries.append(NetdiskFixtures.video("第\(index)讲 高数强化.mp4", in: "试看", duration: 600))
        }
        let packages = NetdiskFixtures.digest(entries).packages
        XCTAssertEqual(packages.count, 2)
        let report = NetdiskDedup.scan(packages: packages)
        XCTAssertTrue(report.droppedPackages.allSatisfy { $0.requiresReview },
                      "试看只是子集，绝不能自动丢掉其他课程")
    }

    // MARK: - 与应用内已有课程

    func testCourseAlreadyInThePlanIsMatched() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        var lessons: [WebCourseLesson] = []
        for index in 1...5 {
            entries.append(NetdiskFixtures.video("第\(index)讲 高数强化.mp4", in: "课程", duration: 600))
            lessons.append(WebCourseLesson(id: "old-\(index)", name: "第\(index)讲 高数强化", subject: "",
                                           stage: "", chapter: "课程", kind: "video", published: true,
                                           durationSeconds: 600, watchedPercent: 0, markedFinished: false,
                                           requiresDuration: true))
        }
        let package = try package(entries, path: "课程")
        var existing = Course(name: "高数强化", totalMinutes: 50, startDate: Date(), deadline: Date())
        existing.webCourse = WebCourseSnapshot(packageID: "old", name: "高数强化", sourceURL: "",
                                               fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                                               lessons: lessons, issues: [])
        let report = NetdiskDedup.scan(packages: [package], courses: [existing])
        let match = try XCTUnwrap(report.existingCourseMatches.first)
        XCTAssertEqual(match.courseID, existing.id)
        XCTAssertEqual(match.overlapRatio, 1, accuracy: 0.001)
        XCTAssertTrue(match.reason.contains("已有这门课"))
    }

    func testUnrelatedCourseIsNotMatched() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        for index in 1...4 {
            entries.append(NetdiskFixtures.video("第\(index)讲 概率基础.mp4", in: "课程", duration: 600))
        }
        let package = try package(entries, path: "课程")
        var other = Course(name: "线代强化", totalMinutes: 60, startDate: Date(), deadline: Date())
        other.manualLessons = (1...4).map { ManualLesson(name: "第\($0)讲 线性代数", durationMinutes: 15) }
        let report = NetdiskDedup.scan(packages: [package], courses: [other])
        XCTAssertTrue(report.existingCourseMatches.isEmpty)
    }
}
