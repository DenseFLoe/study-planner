import XCTest
@testable import StudyCore

final class CourseCatalogSearchTests: XCTestCase {
    private let deadline = Date(timeIntervalSince1970: 1_793_810_000)
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func course(_ name: String, notes: String = "") -> Course {
        var value = Course(name: name, totalMinutes: 60, startDate: deadline.addingTimeInterval(-86400), deadline: deadline)
        value.notes = notes
        return value
    }
    func testCombinedKeywordsMatchNameNotesAndLocalDeadline() {
        let value = course("ＡＬＰＨＡ 化工", notes: "期末复习")
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = utc; formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: deadline)
        XCTAssertEqual(CourseCatalogSearch.matches(query: " alpha\t期末 \(date)\n", courses: [value], timeZone: utc), [value])
        XCTAssertTrue(CourseCatalogSearch.matches(query: "alpha 缺失词", courses: [value], timeZone: utc).isEmpty)
        XCTAssertEqual(CourseCatalogSearch.matches(query: " \n", courses: [value]), [value])
    }
    func testScopeExcludesArchivedCoursesAndUsesStableDeadlineOrdering() {
        let active = course("自动")
        var paused = course("暂停"), archived = course("归档"), earlier = course("较早")
        paused.autoScheduleEnabled = false; archived.isArchived = true
        earlier.deadline.addTimeInterval(-86400)
        let input = [paused, archived, active, earlier]
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input, scope: .paused), [paused])
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input, scope: .automatic), [earlier, active])
        let tied = [paused, active].sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input), [earlier] + tied)
        XCTAssertEqual(input, [paused, archived, active, earlier])
    }
    func testPriorityOrderKeepsFilteringStableTiesAndSchedulingData() {
        var high = course("重点 高"), tied = course("重点 同级"), later = course("重点 较晚"), medium = course("中"), low = course("低"), archived = course("归档")
        high.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        tied.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        high.priority = 3; tied.priority = 3; later.priority = 3; low.priority = 1
        later.deadline.addTimeInterval(86400); medium.deadline.addTimeInterval(-86400); low.deadline.addTimeInterval(-172800)
        tied.autoScheduleEnabled = false; archived.isArchived = true; archived.priority = 3
        let input = [low, archived, later, tied, medium, high], before = input
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input, order: .priority), [high, tied, later, medium, low])
        XCTAssertEqual(CourseCatalogSearch.matches(query: "重点", courses: input, scope: .automatic, order: .priority), [high, later])
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input, scope: .paused, order: .priority), [tied])
        XCTAssertEqual(CourseCatalogSearch.matches(query: "", courses: input), [low, medium, high, tied, later])
        XCTAssertTrue(CourseCatalogSearch.matches(query: "不存在", courses: input, order: .priority).isEmpty)
        XCTAssertEqual(input, before)
    }

    func testDeadlineSearchUsesTheRequestedLocalDay() {
        var value = course("午夜")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = utc
        value.deadline = calendar.date(from: .init(year: 2026, month: 11, day: 4, hour: 20))!
        XCTAssertEqual(CourseCatalogSearch.matches(query: "2026-11-05", courses: [value], timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), [value])
        XCTAssertTrue(CourseCatalogSearch.matches(query: "2026-11-05", courses: [value], timeZone: utc).isEmpty)
    }
    func testLargeCatalogSearchPreservesSourceAndFindsCrossFieldMatches() {
        let courses = (0..<10_000).map { index in
            course("科目 \(index)", notes: index.isMultiple(of: 100) ? "target" : "其他")
        }
        let result = CourseCatalogSearch.matches(query: "科目 TARGET", courses: courses, timeZone: utc)
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(Set(result.map(\.id)), Set(courses.enumerated().filter { $0.offset.isMultiple(of: 100) }.map { $0.element.id }))
        XCTAssertEqual(courses[0].name, "科目 0"); XCTAssertEqual(courses.count, 10_000)
    }
}
