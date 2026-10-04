import XCTest
@testable import StudyPlanner

final class WeeklyChartSeriesTests: XCTestCase {
    private func segment(_ day: Int, _ course: String, _ minutes: Int = 60) -> WeeklyBarSegment {
        WeeklyBarSegment(dayIndex: day, dayLabel: "周\(day)", courseName: course, minutes: minutes)
    }

    /// The chart crashed on launch once a fifth course had work in the same week,
    /// because the foreground-style scale domain was truncated to four names.
    func testDomainCoversEverySeriesBeyondTheLegendLimit() {
        let segments = (0..<6).map { segment($0, "课程\($0)") }
        let names = WeeklyChartSeries.names(in: segments)
        XCTAssertEqual(names.count, 6)
        XCTAssertEqual(Set(names), Set(segments.map(\.courseName)), "domain 必须覆盖数据里出现的每一门课程")
    }

    func testNamesAreUniqueAndKeepFirstAppearanceOrder() {
        let segments = [segment(0, "数学"), segment(0, "英语"), segment(1, "数学"), segment(2, "政治")]
        XCTAssertEqual(WeeklyChartSeries.names(in: segments), ["数学", "英语", "政治"])
    }

    func testEmptySegmentsProduceEmptyDomain() {
        XCTAssertTrue(WeeklyChartSeries.names(in: []).isEmpty)
    }
}
