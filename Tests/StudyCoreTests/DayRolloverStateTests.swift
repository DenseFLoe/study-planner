import XCTest
@testable import StudyCore

final class DayRolloverStateTests: XCTestCase {
    func testFailedTransitionRetriesAfterDelayAndSuccessAcknowledgesOnlyThatDay() {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000), tomorrow = day.addingTimeInterval(86400)
        var value = DayRolloverState(savedDay: day)
        XCTAssertFalse(value.isDue(day: day, uptime: 100))
        XCTAssertTrue(value.isDue(day: tomorrow, uptime: 100))
        value.failed(day: tomorrow, uptime: 100)
        XCTAssertFalse(value.isDue(day: day, uptime: 100))
        XCTAssertFalse(value.isDue(day: tomorrow, uptime: 399))
        XCTAssertTrue(value.isDue(day: tomorrow, uptime: 400))
        value.failed(day: tomorrow, uptime: 400)
        XCTAssertFalse(value.isDue(day: tomorrow, uptime: 699))
        XCTAssertTrue(value.isDue(day: tomorrow, uptime: 700))
        value.succeeded(day: tomorrow)
        XCTAssertFalse(value.isDue(day: tomorrow, uptime: 999))
        XCTAssertTrue(value.isDue(day: tomorrow.addingTimeInterval(86400), uptime: 999))
    }
    func testDifferentDayAndMonotonicResetCannotBeStalledByOlderFailure() {
        let day = Date(timeIntervalSinceReferenceDate: 800_000_000), tomorrow = day.addingTimeInterval(86400)
        var value = DayRolloverState(savedDay: day)
        value.failed(day: tomorrow, uptime: 1000)
        XCTAssertTrue(value.isDue(day: tomorrow.addingTimeInterval(86400), uptime: 1001))
        XCTAssertTrue(value.isDue(day: tomorrow, uptime: 0))
        XCTAssertTrue(value.isDue(day: day.addingTimeInterval(-86400), uptime: 1001))
        value.succeeded(day: tomorrow)
        XCTAssertTrue(value.isDue(day: day, uptime: 1001))
        value.succeeded(day: day)
        XCTAssertFalse(value.isDue(day: day, uptime: 2000))
    }
}
