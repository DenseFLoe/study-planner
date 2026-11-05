import XCTest
@testable import StudyCore

final class NetdiskMergeCancellationTests: XCTestCase {
    func testMergeChecksCancellationInsideOneLargeSourceAndLeavesInputsIntact() throws {
        let entries = [NetdiskFixtures.folder("01 高数"), NetdiskFixtures.folder("02 线代")]
            + (1...100).map { NetdiskFixtures.video("第\($0)讲.mp4", in: "01 高数", duration: 600) }
            + (1...3).map { NetdiskFixtures.video("第\($0)讲.mp4", in: "02 线代", duration: 900) }
        let packages = NetdiskFixtures.digest(entries).packages
        let scan = NetdiskFixtures.scan(packages: packages)
        let courses = packages.compactMap { NetdiskSnapshotBuilder.build(package: $0, scan: scan) }
        let snapshots = courses.map(\.snapshot), metadata = courses.map(\.lessons)
        var checks = 0
        XCTAssertThrowsError(try NetdiskSnapshotBuilder.merge(courses, name: "合并", scan: scan) {
            checks += 1
            if checks == 25 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 25, "Stop during the first large course, not only between courses")
        XCTAssertEqual(courses.map(\.snapshot), snapshots)
        XCTAssertEqual(courses.map(\.lessons), metadata)
        let ordinary = try XCTUnwrap(NetdiskSnapshotBuilder.merge(courses, name: "合并", scan: scan))
        let cancellable = try XCTUnwrap(NetdiskSnapshotBuilder.merge(courses, name: "合并", scan: scan,
                                                                    checkCancellation: {}))
        XCTAssertEqual(cancellable.snapshot, ordinary.snapshot)
        XCTAssertEqual(cancellable.lessons, ordinary.lessons)
        XCTAssertEqual(cancellable.sourcePackageIDs, ordinary.sourcePackageIDs)
    }

    func testCancelledMergeDoesNotStartEvenForInvalidInput() {
        XCTAssertThrowsError(try NetdiskSnapshotBuilder.merge([], name: "", scan: NetdiskFixtures.scan(packages: [])) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
    }

    func testLessonSortCanStopWhileBuildingKeysAndComparingThem() {
        let items = (1...100).reversed().map {
            LessonWorkItem(id: "\($0)", name: "第\($0)讲", subject: "数学", stage: "基础", chapter: "第一章",
                           durationMinutes: 10, remainingMinutes: 10)
        }
        // One initial check and one per key precede comparator checks.
        for limit in [20, items.count + 10] {
            var checks = 0
            XCTAssertThrowsError(try LessonOrdering.intelligent(items) {
                checks += 1
                if checks == limit { throw CancellationError() }
            }) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, limit)
        }
        XCTAssertEqual(LessonOrdering.intelligent(items).map(\.id), (1...100).map(String.init))
    }
}
