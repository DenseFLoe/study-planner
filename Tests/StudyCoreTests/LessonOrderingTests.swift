import XCTest
@testable import StudyCore

final class LessonOrderingTests: XCTestCase {
    private func item(_ name: String, id: String? = nil, chapter: String = "", subject: String = "", stage: String = "") -> LessonWorkItem {
        .init(id: id ?? name, name: name, subject: subject, stage: stage, chapter: chapter,
              durationMinutes: 60, remainingMinutes: 60)
    }

    func testSmartSortUsesSuffixNumberBeforeDifferentTopicText() {
        XCTAssertEqual(LessonOrdering.intelligent([item("01线性代数xxxx13"), item("01线性代数xxxx12")]).map(\.name),
                       ["01线性代数xxxx12", "01线性代数xxxx13"])
        let lessons = [item("01线性代数矩阵13.mp4"), item("01线性代数行列式12.mp4"), item("01线性代数向量2.mp4")]
        XCTAssertEqual(LessonOrdering.intelligent(lessons).map(\.name),
                       ["01线性代数向量2.mp4", "01线性代数行列式12.mp4", "01线性代数矩阵13.mp4"])
    }

    func testSmartSortGroupsSubjectStageAndChapterBeforeLesson() {
        let lessons = [item("第1讲", id: "last", chapter: "第十章", subject: "线代"),
                       item("第12讲", id: "second", chapter: "第二章", subject: "线代"),
                       item("第2讲", id: "first", chapter: "第二章", subject: "线代")]
        XCTAssertEqual(LessonOrdering.intelligent(lessons).map(\.id), ["first", "second", "last"])
        let stages = [item("第1讲", id: "b", stage: "02强化"), item("第13讲", id: "a", stage: "01基础")]
        XCTAssertEqual(LessonOrdering.intelligent(stages).map(\.id), ["a", "b"])
    }

    func testSmartSortNormalizesCountersPaddingQualityAndParts() {
        let lessons = [item("【01】第十三讲 矩阵"), item("【99】第十二讲 行列式"), item("第２讲 向量 1080p.mp4")]
        XCTAssertEqual(LessonOrdering.intelligent(lessons).map(\.name),
                       ["第２讲 向量 1080p.mp4", "【99】第十二讲 行列式", "【01】第十三讲 矩阵"])
        let padded = [item("01线代13"), item("1线代12")]
        XCTAssertEqual(LessonOrdering.intelligent(padded).map(\.name), ["1线代12", "01线代13"])
        let parts = [item("第2讲 矩阵（下）"), item("第2讲 矩阵（上）"), item("第2讲 矩阵（中）")]
        XCTAssertEqual(LessonOrdering.intelligent(parts).map(\.name),
                       ["第2讲 矩阵（上）", "第2讲 矩阵（中）", "第2讲 矩阵（下）"])
        XCTAssertEqual(LessonOrdering.intelligent([item("第2讲 矩阵(10)"), item("第2讲 矩阵(2)")]).map(\.name),
                       ["第2讲 矩阵(2)", "第2讲 矩阵(10)"])
    }

    func testSmartOrderIsIndependentOfInputPermutation() {
        let lessons = [item("7.4 二次型"), item("7.01 一阶"), item("第十二讲"), item("01线代13"), item("01线代12")]
        let expected = LessonOrdering.intelligent(lessons).map(\.id)
        for _ in 0..<30 { XCTAssertEqual(LessonOrdering.intelligent(lessons.shuffled()).map(\.id), expected) }
    }

    func testBatchMoveKeepsSelectedRelativeOrder() {
        let original = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(LessonOrdering.move(original, selected: ["b", "d"], before: 0), ["b", "d", "a", "c", "e"])
        XCTAssertEqual(LessonOrdering.move(original, selected: ["b", "d"], before: 5), ["a", "c", "e", "b", "d"])
        XCTAssertEqual(LessonOrdering.move(original, selected: ["b", "d"], before: 3), ["a", "c", "b", "d", "e"])
        XCTAssertEqual(LessonOrdering.move(original, selected: [], before: 0), original)
    }

    func testRefreshKeepsExistingOrderAndAppendsNewLessons() throws {
        func snapshot(_ ids: [String]) -> WebCourseSnapshot {
            .init(packageID: "package", name: "录播", sourceURL: "https://example.com/course",
                  fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                  lessons: ids.map { .init(id: $0, name: $0, subject: "", stage: "", chapter: "",
                                        kind: "video", published: true, durationSeconds: 1800,
                                        watchedPercent: 0, markedFinished: false, requiresDuration: true) }, issues: [])
        }
        let now = Date()
        var state = PlannerState()
        try state.importWebCourses([snapshot(["a", "b", "c"])], deadline: now.addingTimeInterval(86400), now: now)
        state.courses[0].lessonOrder = ["c", "a", "b"]
        state.courses[0].lessonOrderCustomized = true
        try state.importWebCourses([snapshot(["b", "c", "a", "d"])], deadline: now.addingTimeInterval(86400), now: now)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), ["c", "a", "b", "d"])
        XCTAssertEqual(try JSONDecoder().decode(PlannerState.self, from: JSONEncoder().encode(state)), state)
    }

    func testWebsiteOrderIsDefaultAndRefreshFollowsWebsite() throws {
        func snapshot(_ ids: [String]) -> WebCourseSnapshot {
            .init(packageID: "website", name: "录播", sourceURL: "https://example.com/course",
                  fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                  lessons: ids.map { .init(id: $0, name: $0, subject: "", stage: "", chapter: "",
                                        kind: "video", published: true, durationSeconds: 1800,
                                        watchedPercent: 0, markedFinished: false, requiresDuration: true) }, issues: [])
        }
        let now = Date()
        let deadline = now.addingTimeInterval(86400)
        var state = PlannerState()
        try state.importWebCourses([snapshot(["第三节", "第一节", "第二节"])], deadline: deadline, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), ["第三节", "第一节", "第二节"])
        XCTAssertEqual(state.courses[0].lessonOrderCustomized, false)

        try state.importWebCourses([snapshot(["第二节", "第三节", "第一节", "第四节"])], deadline: deadline, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), ["第二节", "第三节", "第一节", "第四节"])
    }

    func testLegacyAutomaticSmartOrderMigratesToWebsiteOrder() throws {
        let now = Date(), deadline = now.addingTimeInterval(86400)
        func snapshot(_ ids: [String]) -> WebCourseSnapshot {
            .init(packageID: "legacy", name: "录播", sourceURL: "https://example.com/course",
                  fetchedAt: now, expectedOutlines: 1, fetchedOutlines: 1,
                  lessons: ids.map { .init(id: $0, name: $0, subject: "", stage: "", chapter: "",
                                        kind: "video", published: true, durationSeconds: 1800,
                                        watchedPercent: 0, markedFinished: false, requiresDuration: true) }, issues: [])
        }
        var state = PlannerState()
        try state.importWebCourses([snapshot(["第三节", "第一节", "第二节"])], deadline: deadline, now: now)
        state.courses[0].lessonOrder = LessonOrdering.intelligentIDs(state.courses[0].webCourse!.lessons)
        state.courses[0].lessonOrderCustomized = nil
        try state.importWebCourses([snapshot(["第二节", "第三节", "第一节"])], deadline: deadline, now: now)
        XCTAssertEqual(state.lessonWorkItems(for: state.courses[0]).map(\.id), ["第二节", "第三节", "第一节"])
    }
}
