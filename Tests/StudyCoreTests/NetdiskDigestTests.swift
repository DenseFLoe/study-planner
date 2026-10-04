import XCTest
@testable import StudyCore

/// Covers the pieces that decide what a share contains: link parsing, video recognition,
/// course scoring, lesson ordering, and assembling a schedulable snapshot.
final class NetdiskDigestTests: XCTestCase {

    // MARK: - 链接解析

    func testStandardShareLinkParses() throws {
        let link = try XCTUnwrap(NetdiskLink.parse("https://pan.quark.cn/s/48d8818e6cc0"))
        XCTAssertEqual(link.pwdID, "48d8818e6cc0")
        XCTAssertNil(link.fragmentFID)
        XCTAssertNil(link.inAppPasscode)
    }

    func testLinkWithFolderFragmentParses() throws {
        let link = try XCTUnwrap(NetdiskLink.parse(
            "https://pan.quark.cn/s/48d8818e6cc0#/list/share/8eecf67a439242ddabfc771bc7f57749"))
        XCTAssertEqual(link.pwdID, "48d8818e6cc0")
        XCTAssertEqual(link.fragmentFID, "8eecf67a439242ddabfc771bc7f57749")
    }

    func testLinkWithoutSchemeAndWithPasscodeParses() throws {
        let link = try XCTUnwrap(NetdiskLink.parse("pan.quark.cn/s/abc123?pwd=7x9q"))
        XCTAssertEqual(link.pwdID, "abc123")
        XCTAssertEqual(link.inAppPasscode, "7x9q")
    }

    func testForeignOrUnsafeTextIsRejected() {
        XCTAssertNil(NetdiskLink.parse(""))
        XCTAssertNil(NetdiskLink.parse("https://example.com/s/abc123"))
        XCTAssertNil(NetdiskLink.parse("http://pan.quark.cn/s/abc123"))
        XCTAssertNil(NetdiskLink.parse("https://pan.quark.cn/s/../../../etc/passwd"))
        XCTAssertNil(NetdiskLink.parse("https://pan.quark.cn/1/clouddrive/file/download"))
    }

    // MARK: - 名称归一化与集数

    func testEpisodeExtraction() {
        XCTAssertEqual(NetdiskTitles.episode(in: "第3讲 高数强化.mp4"), 3)
        XCTAssertEqual(NetdiskTitles.episode(in: "第10讲 高数强化.mp4"), 10)
        XCTAssertEqual(NetdiskTitles.episode(in: "12.无穷级数.mp4"), 12)
        XCTAssertEqual(NetdiskTitles.episode(in: "高数5-2定制伴学"), 5)
        XCTAssertEqual(NetdiskTitles.episode(in: "线代1-1定制伴学"), 1)
        XCTAssertEqual(NetdiskTitles.episode(in: "第12讲 绪论.mp4"), 12)
        // A counter beats a decorative brace number, which is only a position label.
        XCTAssertEqual(NetdiskTitles.episode(in: "{11}--第10讲 重积分"), 10)
        XCTAssertEqual(NetdiskTitles.episode(in: "{11}--第10章 重积分"), 11)
        // Resolution markers are never episode numbers.
        XCTAssertEqual(NetdiskTitles.episode(in: "第3讲 极限 1080p.mp4"), 3)
        XCTAssertNil(NetdiskTitles.episode(in: "极限 1080p.mp4"))
        XCTAssertNil(NetdiskTitles.episode(in: "笔记小结"))
        // `第10章` names its chapter, so it orders the lesson without entering the name stem.
        XCTAssertNil(NetdiskTitles.episode(in: "第3章 导数与微分"))
        XCTAssertEqual(NetdiskTitles.parse("第3章 导数与微分").episode, 3)
    }

    func testDecimalLessonNamesStayInNaturalOrderWithinChapter() {
        let names = ["7.4一阶线性微分方程.mp4", "7.1微分方程的基本概念.mp4",
                     "7.10高阶方程.mp4", "7.2可分离变量的微分方程.mp4"]
        let entries = names.map { NetdiskFixtures.video($0, in: "第7章 微分方程") }
        XCTAssertEqual(entries.sorted(by: NetdiskDigest.lessonComparator()).map(\.name),
                       [names[1], names[3], names[0], names[2]])
    }

    func testEpisodeNumberingIsNotPartOfTheNameStem() {
        XCTAssertEqual(NetdiskTitles.parse("第3讲 高数强化.mp4").base, "高数强化")
        XCTAssertEqual(NetdiskTitles.parse("第10讲 高数强化.mp4").base, "高数强化")
        XCTAssertEqual(NetdiskTitles.parse("12.无穷级数.mp4").base, "无穷级数")
        XCTAssertEqual(NetdiskTitles.parse("第3章 导数与微分").base, "导数与微分")
        XCTAssertEqual(NetdiskTitles.parse("{11}--第10讲 重积分").base, "重积分")
    }

    func testCopyMarkerAndQualityTagsAreSeparated() {
        let copy = NetdiskTitles.parse("00.高数总结10无穷级数（数一、三） (1).mp4")
        XCTAssertEqual(copy.episode, 0, "开头的 00 是集数")
        XCTAssertEqual(copy.copyIndex, 1, "副本序号单独记录，不混进变体")
        XCTAssertTrue(copy.base.contains("高数总结10无穷级数"), "主干不应被破坏：\(copy.base)")
        // A copy marker says "same file again", so identity must ignore it and let dedup merge them.
        XCTAssertEqual(NetdiskTitles.identity("03.无穷级数.mp4"), NetdiskTitles.identity("03.无穷级数 (1).mp4"))

        let quality = NetdiskTitles.parse("第3讲 极限 [1080p].mp4")
        XCTAssertEqual(quality.base, "极限")
        XCTAssertTrue(quality.variant.contains("1080p"))
        XCTAssertNil(quality.copyIndex)
    }

    func testSameLessonAcrossReleaseVariantsSharesIdentity() {
        XCTAssertEqual(NetdiskTitles.looseIdentity("第3讲 极限.mp4"),
                       NetdiskTitles.looseIdentity("第3讲 极限 1080p 无水印.mp4"))
        XCTAssertNotEqual(NetdiskTitles.looseIdentity("第3讲 极限.mp4"),
                          NetdiskTitles.looseIdentity("第4讲 极限.mp4"))
        XCTAssertNotEqual(NetdiskTitles.looseIdentity("01 2017年真题金解01.mp4"),
                          NetdiskTitles.looseIdentity("01 2018年真题金解01.mp4"),
                          "年份是课程标题的一部分，不能当作装饰编号丢掉")
    }

    func testSimilarityIgnoresNumberingAndNoise() {
        XCTAssertEqual(NetdiskTitles.similarity("第3讲 高数强化", "第3讲 高数强化 1080p"), 1)
        XCTAssertEqual(NetdiskTitles.similarity("高数强化 武忠祥", "高数强化 武忠祥 完整版"), 1)
        XCTAssertLessThan(NetdiskTitles.similarity("高数强化", "线性代数基础"), 0.2)
        XCTAssertEqual(NetdiskTitles.editDistance("kitten", "sitting"), 3)
    }

    func testNaturalOrderingPutsEpisodeTwoBeforeTen() {
        let names = ["第10讲.mp4", "第2讲.mp4", "01.绪论.mp4", "第1讲.mp4"]
        let sorted = names.sorted { NetdiskTitles.naturalCompare($0, $1) == .orderedAscending }
        XCTAssertEqual(sorted, ["01.绪论.mp4", "第1讲.mp4", "第2讲.mp4", "第10讲.mp4"])
    }

    // MARK: - 视频与文档识别

    func testVideoRecognitionUsesEverySignal() {
        XCTAssertEqual(NetdiskDigest.kind(of: NetdiskFixtures.video("a.mp4")), .video)
        // No extension, no format type, but the provider says category 1.
        let bare = NetdiskEntry(fid: "x", shareToken: "t", name: "第一讲", isDirectory: false, fileType: 1,
                                category: 1, formatType: "", size: 100, durationSeconds: 60, width: nil,
                                height: nil, updatedAt: nil, childCount: nil, riskType: 0, banned: false,
                                badContent: false, status: 1, parentPath: "")
        XCTAssertEqual(NetdiskDigest.kind(of: bare), .video)
        let mimeOnly = NetdiskEntry(fid: "y", shareToken: "t", name: "opens", isDirectory: false, fileType: 1,
                                    category: 0, formatType: "video/x-matroska", size: 100, durationSeconds: 60,
                                    width: nil, height: nil, updatedAt: nil, childCount: nil, riskType: 0,
                                    banned: false, badContent: false, status: 1, parentPath: "")
        XCTAssertEqual(NetdiskDigest.kind(of: mimeOnly), .video)
        XCTAssertEqual(NetdiskDigest.kind(of: NetdiskFixtures.pdf("讲义.pdf")), .document)
        XCTAssertEqual(NetdiskDigest.kind(of: NetdiskFixtures.folder("02 课程")), .other)
    }

    func testSavedCourseRetainsFilePathWithoutShareToken() throws {
        var course = Course(name: "高数基础", totalMinutes: 60, startDate: Date(), deadline: Date())
        course.netdisk = NetdiskSnapshot(pwdID: "abc123", shareTitle: "测试分享", folderPath: "高数基础",
                                         sourceURL: "https://pan.quark.cn/s/abc123", fetchedAt: Date(),
                                         videoCount: 1, totalBytes: 123, unknownDurations: 0,
                                         detection: "课程判定 90 分", duplicates: nil)
        course.netdiskLessons = ["lesson": NetdiskLessonMeta(fid: "file1", path: "高数基础/第1讲.mp4",
                                                              size: 123, width: 1920, height: 1080,
                                                              estimatedDuration: false,
                                                              shareToken: "temporary-secret")]
        let encoded = try JSONEncoder().encode(course)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("temporary-secret"))
        let restored = try JSONDecoder().decode(Course.self, from: encoded)
        XCTAssertEqual(restored.netdiskLessons?["lesson"]?.path, "高数基础/第1讲.mp4")
        XCTAssertNil(restored.netdiskLessons?["lesson"]?.shareToken)
    }

    func testUnplayableFilesAreNotLessons() {
        let blocked = NetdiskEntry(fid: "bad", shareToken: "t", name: "被屏蔽.mp4", isDirectory: false,
                                   fileType: 1, category: 1, formatType: "video/mp4", size: 1_000, durationSeconds: 600,
                                   width: 1280, height: 720, updatedAt: nil, childCount: nil, riskType: 1,
                                   banned: false, badContent: false, status: 1, parentPath: "")
        XCTAssertFalse(NetdiskDigest.isPlayable(blocked))
        let outcome = NetdiskFixtures.digest([NetdiskFixtures.folder("课程"), blocked])
        XCTAssertTrue(outcome.packages.isEmpty)
    }

    // MARK: - 课程判定

    func testCourseFolderWithNumberedVideosIsDetected() throws {
        var entries = [NetdiskFixtures.folder("02 课程【视频课在这里】")]
        entries.append(NetdiskFixtures.folder("01 视频【视频课在这里】", in: "02 课程【视频课在这里】"))
        for index in 1...6 {
            entries.append(NetdiskFixtures.video("第\(index)讲 高数强化.mp4",
                                                 in: "02 课程【视频课在这里】/01 视频【视频课在这里】"))
        }
        let outcome = NetdiskFixtures.digest(entries)
        let package = try XCTUnwrap(outcome.packages.first)
        XCTAssertEqual(package.videoCount, 6)
        XCTAssertGreaterThan(package.signal.score, 0.6)
        XCTAssertEqual(package.signal.videoRatio, 1)
        XCTAssertEqual(package.packageID, "quark:48d8818e6cc0:dir-01 视频【视频课在这里】")
    }

    func testDocumentFolderIsNotOfferedAsCourse() throws {
        // The real share's "00 书籍讲义" folder: many pdfs, no videos.
        var entries = [NetdiskFixtures.folder("00 书籍讲义")]
        for index in 1...20 { entries.append(NetdiskFixtures.pdf("第\(index)章 讲义.pdf", in: "00 书籍讲义")) }
        entries.append(NetdiskFixtures.folder("课程"))
        for index in 1...5 { entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "课程")) }
        let outcome = NetdiskFixtures.digest(entries)
        XCTAssertEqual(outcome.packages.map(\.path), ["课程"])
    }

    func testChaptersStayInsideOneCourse() {
        let root = "01 高数基础"
        var entries = [NetdiskFixtures.folder(root),
                       NetdiskFixtures.folder("第1章 函数", in: root),
                       NetdiskFixtures.folder("第2章 极限", in: root)]
        for index in 1...3 {
            entries.append(NetdiskFixtures.video("第\(index)讲 函数.mp4", in: root + "/第1章 函数"))
            entries.append(NetdiskFixtures.video("第\(index)讲 极限.mp4", in: root + "/第2章 极限"))
        }
        let outcome = NetdiskFixtures.digest(entries)
        XCTAssertEqual(outcome.packages.map(\.path), [root])
        XCTAssertEqual(outcome.packages.first?.videoCount, 6)
    }

    func testMaterialContainerDoesNotDuplicateChildCourses() {
        let parent = "00 书籍讲义"
        var entries = [NetdiskFixtures.folder(parent),
                       NetdiskFixtures.folder("数一660题", in: parent),
                       NetdiskFixtures.folder("数二660题", in: parent)]
        for index in 1...5 {
            entries.append(NetdiskFixtures.video("第\(index)题 数一讲解.mp4", in: parent + "/数一660题"))
            entries.append(NetdiskFixtures.video("第\(index)题 数二讲解.mp4", in: parent + "/数二660题"))
        }
        let outcome = NetdiskFixtures.digest(entries)
        XCTAssertEqual(Set(outcome.packages.map(\.path)),
                       Set([parent + "/数一660题", parent + "/数二660题"]))
        XCTAssertEqual(outcome.packages.reduce(0) { $0 + $1.videoCount }, 10)
    }

    func testNumberedOneVideoFoldersBecomeOneCourse() {
        let parent = "高数教材基础"
        var entries = [NetdiskFixtures.folder(parent),
                       NetdiskFixtures.folder("扫码视频", in: parent)]
        for index in 1...4 {
            let folder = String(format: "高数教材基础%02d", index)
            entries.append(NetdiskFixtures.folder(folder, in: parent))
            entries.append(NetdiskFixtures.video("第\(index)讲 高数基础.mp4", in: parent + "/" + folder))
            entries.append(NetdiskFixtures.video("第\(index)讲 扫码讲解.mp4", in: parent + "/扫码视频"))
        }
        let outcome = NetdiskFixtures.digest(entries)
        XCTAssertEqual(outcome.packages.count, 2)
        let merged = outcome.packages.first { $0.signal.notes.contains { $0.contains("连续编号") } }
        XCTAssertEqual(merged?.videoCount, 4)
        XCTAssertEqual(outcome.packages.reduce(0) { $0 + $1.videoCount }, 8)
    }

    func testSparseVideoFolderIsFlaggedRatherThanTrusted() throws {
        var entries = [NetdiskFixtures.folder("01 课件")]
        entries.append(NetdiskFixtures.folder("【已加水印】", in: "01 课件"))
        entries.append(NetdiskFixtures.video("试看.mp4", in: "01 课件/【已加水印】"))
        entries.append(NetdiskFixtures.pdf("讲义.pdf", in: "01 课件/【已加水印】"))
        let package = try XCTUnwrap(NetdiskFixtures.package(entries))
        XCTAssertLessThan(package.signal.score, 0.62, "少量视频混在资料里不应自动勾选")
        XCTAssertTrue(package.signal.notes.contains { $0.contains("视频少于") })
    }

    func testNestedStageFoldersBecomeSeparateCourses() throws {
        // Mirrors the real share: 02 课程 / 01 视频 / 01.抢跑预备 … 10.真题阶段.
        var entries = [NetdiskFixtures.folder("02 课程【视频课在这里】"),
                       NetdiskFixtures.folder("01 视频【视频课在这里】", in: "02 课程【视频课在这里】")]
        let stages = ["01.抢跑预备", "02.核心基础", "10.真题阶段"]
        for stage in stages {
            entries.append(NetdiskFixtures.folder(stage, in: "02 课程【视频课在这里】/01 视频【视频课在这里】"))
            for index in 1...4 {
                entries.append(NetdiskFixtures.video("0\(index).高数\(stage).mp4",
                                                     in: "02 课程【视频课在这里】/01 视频【视频课在这里】/\(stage)"))
            }
        }
        let outcome = NetdiskFixtures.digest(entries)
        let expected = stages.map { "02 课程【视频课在这里】/01 视频【视频课在这里】/" + $0 }
        XCTAssertEqual(outcome.packages.map(\.path).sorted(), expected.sorted())
        XCTAssertTrue(outcome.packages.allSatisfy { $0.videoCount == 4 },
                      "容器目录不能吞掉子课程：\(outcome.packages.map { ($0.path, $0.videoCount) })")
    }

    func testCourseNamesCoverNestingDepths() throws {
        let scan = NetdiskFixtures.scan(packages: [])
        let stages = ["01.抢跑预备", "02.核心基础"]

        // Two stages under one collection folder: the collection is a container, the stages are courses.
        var nested: [NetdiskEntry] = [NetdiskFixtures.folder("02 课程【视频课在这里】"),
                                      NetdiskFixtures.folder("01 视频【视频课在这里】", in: "02 课程【视频课在这里】")]
        for stage in stages {
            nested.append(NetdiskFixtures.folder(stage, in: "02 课程【视频课在这里】/01 视频【视频课在这里】"))
            for index in 1...4 {
                nested.append(NetdiskFixtures.video("0\(index).高数.mp4",
                                                    in: "02 课程【视频课在这里】/01 视频【视频课在这里】/\(stage)"))
            }
        }
        let outcome = NetdiskFixtures.digest(nested)
        XCTAssertEqual(outcome.packages.count, stages.count)
        XCTAssertEqual(outcome.packages.map(\.name), stages)
        for package in outcome.packages {
            // `01 视频 · 01.抢跑预备`, never the whole share wrapper.
            XCTAssertTrue(NetdiskSnapshotBuilder.displayName(package: package, scan: scan).hasPrefix("01 视频【视频课在这里】 · "))
        }

        // A single stage: its collection folder becomes the course and names it from above.
        var single: [NetdiskEntry] = [NetdiskFixtures.folder("02 课程【视频课在这里】"),
                                      NetdiskFixtures.folder("01 视频【视频课在这里】", in: "02 课程【视频课在这里】"),
                                      NetdiskFixtures.folder("01.抢跑预备",
                                                             in: "02 课程【视频课在这里】/01 视频【视频课在这里】")]
        for index in 1...4 {
            single.append(NetdiskFixtures.video("第\(index)讲.mp4",
                                                in: "02 课程【视频课在这里】/01 视频【视频课在这里】/01.抢跑预备"))
        }
        let one = try XCTUnwrap(NetdiskFixtures.digest(single).packages.first)
        XCTAssertEqual(one.path, "02 课程【视频课在这里】/01 视频【视频课在这里】")
        XCTAssertEqual(NetdiskSnapshotBuilder.displayName(package: one, scan: scan),
                       "02 课程【视频课在这里】 · 01 视频【视频课在这里】")

        // A course at the share root keeps its own folder name.
        var top: [NetdiskEntry] = [NetdiskFixtures.folder("01 抢跑预备")]
        for index in 1...4 { top.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "01 抢跑预备")) }
        let rootPackage = try XCTUnwrap(NetdiskFixtures.digest(top).packages.first)
        XCTAssertEqual(rootPackage.path, "01 抢跑预备")
        XCTAssertEqual(NetdiskSnapshotBuilder.displayName(package: rootPackage, scan: scan), "01 抢跑预备")
    }

    func testLessonOrderFollowsFoldersThenEpisodeNumbers() throws {
        var entries: [NetdiskEntry] = [NetdiskFixtures.folder("课程"), NetdiskFixtures.folder("02.基础", in: "课程"),
                                       NetdiskFixtures.folder("10.冲刺", in: "课程")]
        entries.append(NetdiskFixtures.video("第10讲.mp4", in: "课程/10.冲刺"))
        entries.append(NetdiskFixtures.video("第2讲.mp4", in: "课程/02.基础"))
        entries.append(NetdiskFixtures.video("第10讲.mp4", in: "课程/02.基础"))
        entries.append(NetdiskFixtures.video("第1讲.mp4", in: "课程/02.基础"))
        let outcome = NetdiskFixtures.digest(entries)
        let basic = try XCTUnwrap(outcome.packages.first { $0.path == "课程/02.基础" })
        let sprint = try XCTUnwrap(outcome.packages.first { $0.path == "课程/10.冲刺" })
        XCTAssertEqual(basic.videos.map(\.parentPath), ["课程/02.基础", "课程/02.基础", "课程/02.基础"])
        XCTAssertEqual(basic.videos.compactMap { NetdiskTitles.episode(in: $0.name) }, [1, 2, 10],
                       "同一文件夹内按集数自然序，第2讲在第10讲前")
        XCTAssertEqual(sprint.videos.map(\.name), ["第10讲.mp4"])
    }

    // MARK: - 生成快照

    func testSnapshotCarriesDurationsAndIsSchedulable() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        for index in 1...5 {
            entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "课程", duration: Double(index) * 600))
        }
        let scan = NetdiskFixtures.scan(packages: [])
        let package = try XCTUnwrap(NetdiskFixtures.package(entries, path: "课程"))
        let course = try XCTUnwrap(NetdiskSnapshotBuilder.build(package: package, scan: scan))
        XCTAssertNil(course.refusal)
        XCTAssertEqual(course.snapshot.lessons.count, 5)
        XCTAssertEqual(course.snapshot.totalMinutes, 150, "600+1200+1800+2400+3000 秒 = 150 分钟")
        XCTAssertNil(course.snapshot.importProblem)
        XCTAssertEqual(course.estimatedLessons, 0)
        XCTAssertEqual(course.snapshot.lessons.first?.name, "第1讲")
        XCTAssertEqual(course.snapshot.lessons.first?.chapter, "课程")
        XCTAssertTrue(course.snapshot.lessons.allSatisfy { $0.requiresDuration && $0.published })
        XCTAssertEqual(course.lessons.count, 5)
    }

    func testMissingDurationsAreEstimatedFromTheCourseMedian() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第1讲.mp4", in: "课程", duration: 600))
        entries.append(NetdiskFixtures.video("第2讲.mp4", in: "课程", duration: 900))
        entries.append(NetdiskFixtures.video("第3讲.mp4", in: "课程", duration: 1200))
        entries.append(NetdiskFixtures.video("第4讲.mp4", in: "课程", duration: nil))
        let package = try XCTUnwrap(NetdiskFixtures.package(entries, path: "课程"))
        let scan = NetdiskFixtures.scan(packages: [package])
        let course = try XCTUnwrap(NetdiskSnapshotBuilder.build(package: package, scan: scan))
        XCTAssertNil(course.refusal)
        XCTAssertEqual(course.estimatedLessons, 1)
        let estimated = try XCTUnwrap(course.lessons.values.first { $0.estimatedDuration })
        XCTAssertEqual(estimated.fid, "vid-课程-第4讲.mp4")
        XCTAssertEqual(course.snapshot.lessons.first { $0.name == "第4讲" }?.durationSeconds, 900)
        XCTAssertTrue(course.notes.contains { $0.contains("估算") })
        XCTAssertTrue(course.snapshot.issues.isEmpty, "估算提示不能被网站快照当作抓取失败")
        XCTAssertNil(course.snapshot.importProblem)

        var state = PlannerState()
        let now = Date(timeIntervalSince1970: 1_790_497_416)
        try state.importNetdiskCourses([course], scan: scan, duplicates: .init(),
                                       deadline: now.addingTimeInterval(90 * 86_400), now: now)
        XCTAssertEqual(state.courses.count, 1)
        XCTAssertNotNil(state.courses[0].netdisk)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).count, 4)
    }

    func testMergedCoursesSortLessonsAndPreserveManualOrderOnRefresh() throws {
        var entries = [NetdiskFixtures.folder("01 高数"), NetdiskFixtures.folder("02 线代")]
        for number in [10, 2, 1] {
            entries.append(NetdiskFixtures.video("第\(number)讲 高数.mp4", in: "01 高数", duration: 600))
        }
        for number in [5, 3, 4] {
            entries.append(NetdiskFixtures.video("第\(number)讲 线代.mp4", in: "02 线代", duration: 900))
        }
        let packages = NetdiskFixtures.digest(entries).packages
        XCTAssertEqual(packages.count, 2)
        let scan = NetdiskFixtures.scan(packages: packages)
        let sources = packages.compactMap { NetdiskSnapshotBuilder.build(package: $0, scan: scan) }
        let merged = try XCTUnwrap(NetdiskSnapshotBuilder.merge(sources, name: "  数学合集  ", scan: scan))
        XCTAssertNil(merged.refusal)
        XCTAssertEqual(merged.name, "数学合集")
        XCTAssertEqual(merged.snapshot.lessons.map(\.name),
                       ["第1讲 高数", "第2讲 高数", "第10讲 高数", "第3讲 线代", "第4讲 线代", "第5讲 线代"])
        XCTAssertEqual(merged.lessons.count, 6)
        XCTAssertEqual(merged.sourcePackageIDs.count, 2)
        XCTAssertEqual(NetdiskSnapshotBuilder.merge(Array(sources.reversed()), name: "数学合集", scan: scan)?.packageID,
                       merged.packageID, "勾选顺序变化不应创建另一门课程")

        let now = Date()
        var state = PlannerState()
        try state.importNetdiskCourses([merged], scan: scan, duplicates: .init(),
                                       deadline: now.addingTimeInterval(90 * 86_400), now: now)
        XCTAssertEqual(state.courses.count, 1)
        XCTAssertEqual(state.courses[0].netdisk?.sourcePackageIDs, merged.sourcePackageIDs)
        XCTAssertEqual(state.courses[0].netdiskLessons?.count, 6)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.name), merged.snapshot.lessons.map(\.name))

        let reversed = merged.snapshot.lessons.map(\.id).reversed()
        state.courses[0].lessonOrder = Array(reversed)
        state.courses[0].lessonOrderCustomized = true
        let originalID = state.courses[0].id
        try state.importNetdiskCourses([merged], scan: scan, duplicates: .init(),
                                       deadline: now.addingTimeInterval(90 * 86_400), now: now)
        XCTAssertEqual(state.courses.count, 1)
        XCTAssertEqual(state.courses[0].id, originalID)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), Array(reversed))
        let restored = try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.courses[0].netdisk?.sourcePackageIDs, merged.sourcePackageIDs)
        XCTAssertEqual(restored.lessonWorkItems(for: restored.courses[0]).map(\.id), Array(reversed))
        XCTAssertTrue(restored.courses[0].netdiskLessons?.values.allSatisfy { $0.shareToken == nil } == true)
    }

    func testTooFewKnownDurationsRefusesImportInsteadOfGuessing() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        entries.append(NetdiskFixtures.video("第1讲.mp4", in: "课程", duration: nil))
        entries.append(NetdiskFixtures.video("第2讲.mp4", in: "课程", duration: nil))
        entries.append(NetdiskFixtures.video("第3讲.mp4", in: "课程", duration: 600))
        entries.append(NetdiskFixtures.video("第4讲.mp4", in: "课程", duration: nil))
        let package = try XCTUnwrap(NetdiskFixtures.package(entries, path: "课程"))
        let course = try XCTUnwrap(NetdiskSnapshotBuilder.build(package: package, scan: NetdiskFixtures.scan(packages: [])))
        XCTAssertNotNil(course.refusal)
        XCTAssertTrue(course.refusal?.contains("无法估算") == true)
    }

    func testEmptyOrUnknownDurationCourseIsRefused() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        for index in 1...4 { entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "课程", duration: nil)) }
        let package = try XCTUnwrap(NetdiskFixtures.package(entries, path: "课程"))
        let course = try XCTUnwrap(NetdiskSnapshotBuilder.build(package: package, scan: NetdiskFixtures.scan(packages: [])))
        XCTAssertEqual(course.refusal, "网盘没有提供任何视频时长，无法估算学习量。")
    }

    func testPackageIDIsStableAcrossRefetch() throws {
        var entries = [NetdiskFixtures.folder("课程", fid: "abc123")]
        for index in 1...3 { entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "课程")) }
        let first = try XCTUnwrap(NetdiskFixtures.package(entries)).packageID
        entries.append(NetdiskFixtures.video("第4讲.mp4", in: "课程"))
        let second = try XCTUnwrap(NetdiskFixtures.package(entries)).packageID
        XCTAssertEqual(first, second, "课程包编号必须稳定，重复抓取才能更新而不是新建")
    }

    func testCrawlLimitsSuppressWeakCandidates() throws {
        var entries = [NetdiskFixtures.folder("课程")]
        for index in 1...2 { entries.append(NetdiskFixtures.video("第\(index)讲.mp4", in: "课程")) }
        let strict = NetdiskFixtures.digest(entries, limits: NetdiskDigest.Limits(minVideosPerCourse: 5))
        let package = try XCTUnwrap(strict.packages.first)
        XCTAssertLessThan(package.signal.score, 0.62)
    }
}
