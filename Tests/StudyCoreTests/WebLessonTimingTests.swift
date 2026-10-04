import XCTest
@testable import StudyCore

final class WebLessonTimingTests: XCTestCase {
    func testDurationRoundsUpAndSpeedOnlyChangesRemainingTime() throws {
        let value = try XCTUnwrap(WebLessonTiming(duration: 3601, position: 601, rate: 2))
        XCTAssertEqual(value.totalMinutes, 61)
        XCTAssertEqual(value.remainingSeconds, 1500)
        XCTAssertEqual(WebLessonTiming.clock(value.remainingSeconds), "00:25:00")
    }
    func testLiveUnloadedAndInvalidMediaAreRejected() {
        for duration in [Double.infinity, .nan, 0, -1, 36_000_001] {
            XCTAssertNil(WebLessonTiming(duration: duration, position: 0, rate: 1))
        }
        XCTAssertNil(WebLessonTiming(duration: 60, position: .nan, rate: 1))
        XCTAssertNil(WebLessonTiming(duration: 60, position: 0, rate: 0))
        XCTAssertEqual(WebLessonTiming(duration: 60, position: 61, rate: 1)?.remainingSeconds, 0)
    }
    func testWebsiteURLValidation() {
        XCTAssertNotNil(WebLessonTiming.websiteURL(" https://www.kaoyanvip.cn/appmanage/my/mycourse?unit_id=OT11784802 "))
        for text in ["file:///tmp/a", "javascript:alert(1)", "http://example.com", "https://", "https://user:secret@example.com"] {
            XCTAssertNil(WebLessonTiming.websiteURL(text))
        }
    }
    func url(_ text: String) throws -> URL { try XCTUnwrap(URL(string: text)) }
    func testAddressEntryCompletesBareHostsAndRejectsTheRest() {
        XCTAssertEqual(WebLessonTiming.addressURL(" www.kaoyanvip.cn/appmanage/my/mycourse ")?.absoluteString,
                       "https://www.kaoyanvip.cn/appmanage/my/mycourse")
        XCTAssertEqual(WebLessonTiming.addressURL("example.com")?.absoluteString, "https://example.com")
        for text in ["", "   ", "http://example.com", "ftp://example.com", "not an address", "https://user:secret@example.com"] {
            XCTAssertNil(WebLessonTiming.addressURL(text), text)
        }
    }
    func testCrawlingFollowsTheAddressedSiteOnly() throws {
        let target = try XCTUnwrap(WebLessonTiming.addressURL("https://www.kaoyanvip.cn/appmanage/my/mycourse"))
        XCTAssertTrue(WebLessonTiming.isSameWebsite(current: try url("https://WWW.Kaoyanvip.cn/appmanage/my/mycourse"), target: target))
        XCTAssertTrue(WebLessonTiming.isOnTargetPage(current: try url("https://www.kaoyanvip.cn/appmanage/my/mycourse?unit_id=OT1"), target: target))
        XCTAssertTrue(WebLessonTiming.isOnTargetPage(current: try url("https://www.kaoyanvip.cn/appmanage/my/mycourse/detail"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("https://www.kaoyanvip.cn/"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("https://www.kaoyanvip.cn/login"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("https://evil.example.com/appmanage/my/mycourse"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("http://www.kaoyanvip.cn/appmanage/my/mycourse"), target: target))
    }
    func testBareHostWaitsForADeeperPageBeforeAutoCrawling() throws {
        let target = try XCTUnwrap(WebLessonTiming.addressURL("kaoyanvip.cn"))
        XCTAssertTrue(WebLessonTiming.isSameWebsite(current: try url("https://kaoyanvip.cn/"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("https://kaoyanvip.cn/"), target: target))
        XCTAssertTrue(WebLessonTiming.isOnTargetPage(current: try url("https://kaoyanvip.cn/login"), target: target))
        XCTAssertFalse(WebLessonTiming.isOnTargetPage(current: try url("https://kaoyanvip.cn.evil.com/login"), target: target))
    }
}
