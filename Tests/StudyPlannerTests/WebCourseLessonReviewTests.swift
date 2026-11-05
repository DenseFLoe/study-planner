import XCTest
import StudyCore
@testable import StudyPlanner

final class WebCourseLessonReviewTests: XCTestCase {
    private func lesson(id: String = "lesson", published: Bool = true, required: Bool = true,
                        duration: Double? = 120, progress: Double? = 25, finished: Bool = false) -> WebCourseLesson {
        .init(id: id, name: "极限", subject: "数学二", stage: "强化", chapter: "第三章", kind: "video",
              published: published, durationSeconds: duration, watchedPercent: progress,
              markedFinished: finished, requiresDuration: required)
    }

    func testReviewShowsLocationsAndMeasuredProgressWithoutProviderIDs() {
        let row = WebCourseLessonReview.rows([lesson(id: "PRIVATE_PROVIDER_ID")])[0]
        XCTAssertEqual(row.id, 0)
        XCTAssertEqual(row.title, "1. 极限")
        XCTAssertEqual(row.location, "数学二 / 强化 / 第三章")
        XCTAssertTrue(row.details.contains("00:02:00"))
        XCTAssertTrue(row.details.contains("25.0%"))
        XCTAssertFalse((row.title + row.location + row.details).contains("PRIVATE_PROVIDER_ID"))
        XCTAssertNil(row.problem)
    }

    func testMissingRequiredFieldsRemainVisibleEvenWhenWebsiteMarksFinished() {
        let row = WebCourseLessonReview.rows([lesson(duration: nil, progress: nil, finished: true)])[0]
        XCTAssertTrue(row.problem?.contains("缺少时长") == true)
        XCTAssertTrue(row.problem?.contains("缺少观看进度") == true)
        XCTAssertTrue(row.details.contains("观看进度 未知"))
        XCTAssertTrue(row.details.contains("网站标记已完成"))
        XCTAssertFalse(row.details.contains("100.0%"))
        for value in [lesson(published: false, duration: nil, progress: nil), lesson(required: false, duration: nil, progress: nil)] {
            XCTAssertNil(WebCourseLessonReview.rows([value])[0].problem)
        }
    }

    func testInvalidNumericDataIsReportedRatherThanFormattedAsValid() {
        for seconds in [0.0, -1, Double.nan, Double.infinity, 36_000_001] {
            XCTAssertTrue(WebCourseLessonReview.rows([lesson(duration: seconds)])[0].problem?.contains("时长无效") == true)
        }
        for percent in [-1.0, 100.01, Double.nan, Double.infinity] {
            XCTAssertTrue(WebCourseLessonReview.rows([lesson(progress: percent)])[0].problem?.contains("观看进度无效") == true)
        }
        for percent in [0.0, 100] { XCTAssertNil(WebCourseLessonReview.rows([lesson(progress: percent)])[0].problem) }
        XCTAssertNil(WebCourseLessonReview.rows([lesson(duration: 36_000_000)])[0].problem)
    }

    func testDuplicateAndMissingIdentitiesDoNotHideAnyRows() {
        let rows = WebCourseLessonReview.rows([lesson(id: "duplicate"), lesson(id: "duplicate"), lesson(id: "")])
        XCTAssertEqual(rows.map(\.id), [0, 1, 2])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertTrue(rows[0].problem?.contains("重复") == true)
        XCTAssertTrue(rows[1].problem?.contains("重复") == true)
        XCTAssertTrue(rows[2].problem?.contains("缺失") == true)
    }

    func testLargeReviewPreservesTheEntireOriginalOrder() {
        let lessons = (0..<5_001).map { lesson(id: "lesson\($0)", progress: $0 == 5_000 ? nil : 0) }
        let rows = WebCourseLessonReview.rows(lessons)
        XCTAssertEqual(rows.count, 5_001)
        XCTAssertEqual(rows.last?.id, 5_000)
        XCTAssertEqual(rows.last?.title, "5001. 极限")
        XCTAssertTrue(rows.last?.problem?.contains("缺少观看进度") == true)
        XCTAssertNil(lessons.last?.watchedPercent)
    }
}
