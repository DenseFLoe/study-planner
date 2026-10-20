import XCTest
@testable import StudyCore

final class FixedEventTextParserTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }
    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 20, _ hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func parse(_ text: String, now: Date? = nil) -> FixedEventTextResult {
        FixedEventTextParser.parse(text, now: now ?? date(), calendar: calendar)
    }
    private func draft(_ text: String, now: Date? = nil) throws -> FixedEventTextDraft {
        let result = parse(text, now: now)
        XCTAssertEqual(result.drafts.count, 1, result.messages.joined(separator: ";"))
        return try XCTUnwrap(result.drafts.first)
    }

    func testLongNoticeUsesTomorrowRatherThanGraduationYear() throws {
        let notice = "按照学院安排和要求，明天晚上18:00召开示例学院2027届就业及考研动员大会，没有特殊情况必须参会，会议按班级进行，不能参加的同学会后传达内容，会议地点另行通知 @所有人"
        let value = try draft(notice)
        XCTAssertEqual(value.event.startDate, date(2026, 10, 21, 0))
        XCTAssertEqual(value.event.title, "示例学院2027届就业及考研动员大会")
        XCTAssertEqual(value.event.startMinute, 18 * 60)
        XCTAssertEqual(value.event.endMinute, 19 * 60)
        XCTAssertTrue(value.event.weekdays.isEmpty)
        XCTAssertTrue(value.event.notes.contains("会议地点另行通知"))
        XCTAssertTrue(value.warnings.contains { $0.contains("未写结束时间") })
    }
    func testChineseRangeAndWhitespace() throws {
        for text in ["明天下午三点到五点开会", "明天下午 3 点到 5 点开会", "明天下午3:00-5:00开会"] {
            let value = try draft(text)
            XCTAssertEqual(value.event.startMinute, 900)
            XCTAssertEqual(value.event.endMinute, 1020)
            XCTAssertEqual(value.event.title, "开会")
        }
    }
    func testNextWeekUsesMondayBoundaryRegardlessOfCalendarFirstWeekday() throws {
        let value = try draft("下周三下午两点半至四点开会")
        XCTAssertEqual(value.event.startDate, date(2026, 10, 28, 0))
        XCTAssertEqual(value.event.startMinute, 870)
        XCTAssertEqual(value.event.endMinute, 960)
        XCTAssertEqual(try draft("下周一9:00-10:00开会", now: date(2026, 10, 25)).event.startDate, date(2026, 10, 26, 0))
    }
    func testRelativeDatesAcrossYearBoundaryAndMidnight() throws {
        XCTAssertEqual(try draft("明天18:00开会", now: date(2026, 12, 31, 23)).event.startDate, date(2027, 1, 1, 0))
        XCTAssertEqual(try draft("后天18:00开会").event.startDate, date(2026, 10, 22, 0))
        XCTAssertEqual(try draft("大后天18:00开会").event.startDate, date(2026, 10, 23, 0))
        XCTAssertEqual(try draft("今天18:00开会", now: date(2026, 10, 21, 0)).event.startDate, date(2026, 10, 21, 0))
    }
    func testExplicitAndInferredDates() throws {
        XCTAssertEqual(try draft("2026年11月2日 14:00-16:00 讲座").event.startDate, date(2026, 11, 2, 0))
        XCTAssertEqual(try draft("2026-11-02 14:00-16:00 讲座").event.startDate, date(2026, 11, 2, 0))
        let inferred = try draft("1月2日 14:00-16:00 讲座")
        XCTAssertEqual(inferred.event.startDate, date(2027, 1, 2, 0))
        XCTAssertTrue(inferred.warnings.contains { $0.contains("2027") })
    }
    func testRepeatingWeekdaysAndExplicitEnd() throws {
        let value = try draft("从2026年10月20日到2026年12月31日，每周一、三下午3点到5点上课")
        XCTAssertEqual(value.event.weekdays, [2, 4])
        XCTAssertEqual(value.event.startDate, date(2026, 10, 20, 0))
        XCTAssertEqual(value.event.endDate, date(2026, 12, 31, 0))
        XCTAssertFalse(value.warnings.contains { $0.contains("16 周") })
        XCTAssertEqual(try draft("每周一至五9:00-10:00早读").event.weekdays, Set(2...6))
        XCTAssertEqual(try draft("每周五到周一9:00-10:00早读").event.weekdays, [6, 7, 1, 2])
        XCTAssertEqual(try draft("每周一、周三9:00-10:00早读").event.weekdays, [2, 4])
        let until = try draft("每周三19:00-20:00上课，截止2026年12月31日")
        XCTAssertEqual(until.event.startDate, date(2026, 10, 21, 0))
        XCTAssertEqual(until.event.endDate, date(2026, 12, 31, 0))
    }
    func testRepeatDefaultAndDurationAreVisible() throws {
        let value = try draft("每天19:00-20:00锻炼")
        XCTAssertEqual(value.event.weekdays, Set(1...7))
        XCTAssertTrue(value.warnings.contains { $0.contains("16 周") })
        XCTAssertEqual(try draft("每周三9:00-10:00上课，持续4周").event.endDate, date(2026, 11, 17, 0))
        XCTAssertEqual(try draft("工作日9:00-10:00早读").event.weekdays, Set(2...6))
        XCTAssertEqual(try draft("周末9:00-10:00早读").event.weekdays, [1, 7])
    }
    func testDurationAndHalfHours() throws {
        XCTAssertEqual(try draft("明天18:00开会，持续90分钟").event.endMinute, 1170)
        XCTAssertEqual(try draft("明天18:00开会，时长1小时30分钟").event.endMinute, 1170)
        XCTAssertEqual(try draft("明天18:00开会，持续一个半小时").event.endMinute, 1170)
        XCTAssertEqual(try draft("明天18:00开会，持续一小时半").event.endMinute, 1170)
        XCTAssertEqual(try draft("明天下午三点一刻到五点三刻开会").event.startMinute, 915)
    }
    func testRefusesMissingDatesInvalidDatesAndAmbiguousTimes() {
        for text in ["18:00开会", "2026年2月30日18:00开会", "明天25:00开会", "明天上午18:00开会", "明天18:60开会", "明天23:00到次日1:00值班", "明天18:00集合19:00开会", "明天18:00开会后天19:00上课", "明天安排待定"] {
            let result = parse(text)
            XCTAssertTrue(result.drafts.isEmpty, text)
            XCTAssertFalse(result.messages.isEmpty, text)
        }
    }
    func testRefusesConflictingWeekdayAndDate() {
        XCTAssertTrue(parse("2026年10月21日周四18:00开会").drafts.isEmpty)
        XCTAssertEqual(parse("2026年10月21日周三18:00开会").drafts.count, 1)
        XCTAssertEqual(parse("2026年11月2日周一18:00开会").drafts.count, 1)
        XCTAssertEqual(parse("明天周三18:00开会").drafts.count, 1)
    }
    func testMultipleNoticesAndSharedDateHeader() throws {
        let value = parse("明天9:00-10:00开会\n后天14:00-16:00上课")
        XCTAssertEqual(value.drafts.count, 2, value.messages.joined())
        XCTAssertEqual(value.drafts.last?.event.startDate, date(2026, 10, 22, 0))
        XCTAssertEqual(parse("明天18:00开会\n后天19:00上课").drafts.count, 2)
        let shared = parse("明天\n9:00-10:00开会\n14:00-16:00上课")
        XCTAssertEqual(shared.drafts.count, 2, shared.messages.joined())
        XCTAssertTrue(shared.drafts.allSatisfy { $0.event.startDate == date(2026, 10, 21, 0) })
    }
    func testFullwidthAndInputLimits() throws {
        XCTAssertEqual(try draft("明天１８：００至１９：００开会").event.startMinute, 1080)
        XCTAssertTrue(parse(String(repeating: "通知", count: 15001)).drafts.isEmpty)
        XCTAssertTrue(parse(String(repeating: "通知", count: 15001)).messages.first?.contains("30000") == true)
        XCTAssertTrue(parse("").drafts.isEmpty)
        XCTAssertEqual(try draft("明天１８：００至１９：００开会").event.notes, "明天１８：００至１９：００开会")
    }
    func testFloatingAndCancellationAreNotSilentlyConvertedToFixedAppointments() {
        XCTAssertTrue(parse("明天18:00会议取消").drafts.isEmpty)
        XCTAssertTrue(parse("明天14:00到18:00之间任选1小时锻炼").drafts.isEmpty)
    }

    func testUncertainLocationDoesNotDiscardKnownTimeAndDraftsAreCapped() throws {
        let value = try draft("明天18:00召开例会，地点待定")
        XCTAssertEqual(value.event.startMinute, 1080)
        XCTAssertTrue(value.event.notes.contains("地点待定"))
        let text = (1...21).map { "明天9:00-10:00事项\($0)" }.joined(separator: "\n")
        let result = parse(text)
        XCTAssertEqual(result.drafts.count, 20)
        XCTAssertTrue(result.messages.contains { $0.contains("20 条") })
    }
}
