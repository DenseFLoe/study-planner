import XCTest
@testable import StudyPlanner

final class CloudSyncScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPeriodicCheckWaitsTwelveHoursIncludingAfterRestart() {
        var schedule = CloudSyncSchedule(lastAttempt: start)
        for seconds in [0.0, 3600, 43199] {
            schedule.request(.periodic, now: start.addingTimeInterval(seconds))
            XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(seconds)))
        }
        let due = start.addingTimeInterval(43200)
        schedule.request(.periodic, now: due)
        XCTAssertEqual(schedule.nextAttempt(at: due), due)
    }

    func testFirstCheckIsDueWithoutPriorAttempt() {
        var schedule = CloudSyncSchedule()
        schedule.request(.periodic, now: start)
        XCTAssertEqual(schedule.nextAttempt(at: start), start)
    }

    func testBurstOfSavesWaitsForLastSaveThenRunsOnlyOnce() {
        var schedule = CloudSyncSchedule()
        for seconds in [0.0, 0.5, 1.0] { schedule.request(.localChange, now: start.addingTimeInterval(seconds)) }
        XCTAssertEqual(schedule.nextAttempt(at: start), start.addingTimeInterval(3))
        schedule.began(at: start.addingTimeInterval(3))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(4)))
        schedule.finished(success: true, hasLocalChanges: false, now: start.addingTimeInterval(4))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(40)))
    }

    func testInitialAndRepeatedAvailableNetworkDoNotRequestSync() {
        var schedule = CloudSyncSchedule(lastAttempt: start)
        for seconds in [0.0, 1, 60, 3600] {
            schedule.networkChanged(available: true, now: start.addingTimeInterval(seconds))
            XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(seconds)))
        }
        schedule.networkChanged(available: false, now: start.addingTimeInterval(3601))
        schedule.networkChanged(available: true, now: start.addingTimeInterval(3602))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(3602)), start.addingTimeInterval(3602))
    }

    func testEditsAlreadyIncludedInUploadDoNotCauseFollowup() {
        var schedule = CloudSyncSchedule()
        schedule.began(at: start)
        schedule.request(.localChange, now: start.addingTimeInterval(1))
        schedule.request(.networkRestored, now: start.addingTimeInterval(2))
        schedule.request(.periodic, now: start.addingTimeInterval(3))
        schedule.finished(success: true, hasLocalChanges: false, now: start.addingTimeInterval(4))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
    }

    func testUnsyncedEditsGetOneThrottledFollowup() {
        var schedule = CloudSyncSchedule()
        schedule.began(at: start)
        schedule.request(.localChange, now: start.addingTimeInterval(1))
        schedule.finished(success: true, hasLocalChanges: true, now: start.addingTimeInterval(4))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(4)), start.addingTimeInterval(30))
        schedule.began(at: start.addingTimeInterval(30))
        schedule.finished(success: true, hasLocalChanges: false, now: start.addingTimeInterval(31))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
    }

    func testRepairDetectedWithoutNotificationStillGetsUploaded() {
        var schedule = CloudSyncSchedule()
        schedule.began(at: start)
        schedule.finished(success: true, hasLocalChanges: true, now: start.addingTimeInterval(40))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(40)), start.addingTimeInterval(42))
    }

    func testFailureDoesNotCreateUnboundedRetriesButKeepsNewRequest() {
        var schedule = CloudSyncSchedule()
        schedule.began(at: start)
        schedule.finished(success: false, hasLocalChanges: true, now: start.addingTimeInterval(1))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
        schedule.request(.localChange, now: start.addingTimeInterval(2))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(2)), start.addingTimeInterval(30))
        schedule.began(at: start.addingTimeInterval(30))
        schedule.request(.networkRestored, now: start.addingTimeInterval(31))
        schedule.finished(success: false, hasLocalChanges: true, now: start.addingTimeInterval(32))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(32)), start.addingTimeInterval(60))
    }

    func testManualRequestBypassesDelayAndSurvivesInflightSync() {
        var schedule = CloudSyncSchedule()
        schedule.began(at: start)
        schedule.request(.manual, now: start.addingTimeInterval(1))
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(1)))
        schedule.finished(success: true, hasLocalChanges: false, now: start.addingTimeInterval(2))
        XCTAssertEqual(schedule.nextAttempt(at: start.addingTimeInterval(2)), start.addingTimeInterval(2))
    }

    func testOfflineSavesWaitForNetworkAndDisablingClearsRequests() {
        var schedule = CloudSyncSchedule()
        schedule.networkChanged(available: false, now: start)
        schedule.request(.localChange, now: start)
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
        schedule.networkChanged(available: true, now: start.addingTimeInterval(60))
        XCTAssertNotNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
        schedule.request(.manual, now: start.addingTimeInterval(60))
        schedule.cancelPending()
        XCTAssertNil(schedule.nextAttempt(at: start.addingTimeInterval(60)))
    }
}
