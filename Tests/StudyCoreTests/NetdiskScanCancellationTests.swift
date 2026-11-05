import XCTest
@testable import StudyCore

final class NetdiskScanCancellationTests: XCTestCase {
    private func entries() -> [NetdiskEntry] {
        [NetdiskFixtures.folder("高数"), NetdiskFixtures.folder("线代")]
            + ["高数", "线代"].flatMap { folder in
                (1...30).reversed().map {
                    NetdiskFixtures.video("第\($0)讲 极限.mp4", in: folder, duration: 600)
                }
            }
            + [NetdiskFixtures.video("第1讲 极限 (1).mp4", in: "高数", duration: 600)]
    }

    /// Sample early, middle and final checkpoints without timers or thread scheduling races.
    private func assertCancellable<T>(_ operation: (() throws -> Void) throws -> T,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> T {
        var total = 0
        let value = try operation { total += 1 }
        XCTAssertGreaterThan(total, 30, file: file, line: line)
        for stop in [1, 25, total / 2, total - 1, total] {
            var checks = 0
            XCTAssertThrowsError(try operation {
                checks += 1
                if checks == stop { throw CancellationError() }
            }, file: file, line: line) {
                XCTAssertTrue($0 is CancellationError, file: file, line: line)
            }
            XCTAssertEqual(checks, stop, file: file, line: line)
        }
        return value
    }

    func testRecognitionCancelsThroughoutTreeScoringAndSortingWithoutChangingInput() throws {
        let input = entries(), original = input
        let outcome = try assertCancellable {
            try NetdiskDigest.digest(entries: input, rootTitle: "分享", pwdID: "share",
                                     checkCancellation: $0)
        }
        let ordinary = NetdiskDigest.digest(entries: input, rootTitle: "分享", pwdID: "share")
        XCTAssertEqual(input, original)
        XCTAssertEqual(outcome.root, ordinary.root)
        XCTAssertEqual(outcome.packages, ordinary.packages)
        XCTAssertEqual(outcome.totalVideoCount, 61)
    }

    func testDuplicateScanCancelsWithinCoursesAndExistingLessonMatching() throws {
        let packages = NetdiskFixtures.digest(entries()).packages, original = packages
        var existing = Course(name: "高数", totalMinutes: 300, startDate: Date(), deadline: Date())
        existing.manualLessons = (1...30).map { ManualLesson(name: "第\($0)讲 极限", durationMinutes: 10) }
        let report = try assertCancellable {
            try NetdiskDedup.scan(packages: packages, courses: [existing], checkCancellation: $0)
        }
        XCTAssertEqual(report, NetdiskDedup.scan(packages: packages, courses: [existing]))
        XCTAssertFalse(report.withinCourses.isEmpty)
        XCTAssertFalse(report.existingCourseMatches.isEmpty)
        XCTAssertEqual(packages, original)
    }

    func testSnapshotAndSafeCopyRemovalCancelWithoutMutatingPackages() throws {
        let packages = NetdiskFixtures.digest(entries()).packages
        let package = try XCTUnwrap(packages.first { $0.path == "高数" }), original = package
        let scan = NetdiskFixtures.scan(packages: packages)
        let report = NetdiskDedup.scan(packages: packages)
        let cleaned = try assertCancellable {
            try NetdiskDedup.removingSafeCopies(from: package, report: report, checkCancellation: $0)
        }
        XCTAssertEqual(cleaned, NetdiskDedup.removingSafeCopies(from: package, report: report))
        XCTAssertEqual(cleaned.videoCount, 30)
        let candidate = try XCTUnwrap(assertCancellable {
            try NetdiskSnapshotBuilder.build(package: cleaned, scan: scan, checkCancellation: $0)
        })
        let ordinary = try XCTUnwrap(NetdiskSnapshotBuilder.build(package: cleaned, scan: scan))
        XCTAssertEqual(candidate.snapshot, ordinary.snapshot)
        XCTAssertEqual(candidate.lessons, ordinary.lessons)
        XCTAssertEqual(candidate.refusal, ordinary.refusal)
        XCTAssertEqual(package, original)
    }

    func testCancelledEmptyScanDoesNotReturnASuccessfulEmptyResult() {
        XCTAssertThrowsError(try NetdiskDigest.digest(entries: [], rootTitle: "", pwdID: "") {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try NetdiskDedup.scan(packages: []) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
    }
}
