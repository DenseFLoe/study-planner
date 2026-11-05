import XCTest
@testable import StudyCore

final class NetdiskPageProgressTests: XCTestCase {
    func testOverlappingPagesDoNotFinishBeforeAllDistinctFilesArrive() throws {
        var progress = NetdiskPageProgress()
        XCTAssertFalse(try progress.append(ids: ["a", "b"], total: 4).isComplete)
        let overlap = try progress.append(ids: ["b", "c", "c"], total: 4)
        XCTAssertEqual(overlap.newIDs, ["c"])
        XCTAssertFalse(overlap.isComplete)
        XCTAssertEqual(progress.uniqueCount, 3)
        XCTAssertTrue(try progress.append(ids: ["d"], total: 4).isComplete)
        XCTAssertEqual(progress.uniqueCount, 4)
    }

    func testMissingTotalContinuesUntilExplicitEmptyPage() throws {
        var progress = NetdiskPageProgress()
        XCTAssertFalse(try progress.append(ids: ["a"], total: nil).isComplete)
        XCTAssertFalse(try progress.append(ids: ["b"], total: nil).isComplete)
        XCTAssertTrue(try progress.append(ids: [], total: nil).isComplete)
        XCTAssertNil(progress.expectedTotal)
        XCTAssertEqual(progress.uniqueCount, 2)
    }

    func testChangedTotalRejectsPageWithoutChangingProgress() throws {
        var progress = NetdiskPageProgress()
        _ = try progress.append(ids: ["a"], total: 3)
        XCTAssertThrowsError(try progress.append(ids: ["b"], total: 2)) { error in
            XCTAssertEqual(error as? NetdiskPaginationError, .changedDirectory)
        }
        XCTAssertEqual(progress.uniqueCount, 1)
        XCTAssertEqual(progress.expectedTotal, 3)
        XCTAssertTrue(try progress.append(ids: ["b", "c"], total: 3).isComplete)
    }

    func testEmptyPageBeforeReportedTotalIsIncomplete() throws {
        var progress = NetdiskPageProgress()
        _ = try progress.append(ids: ["a"], total: 2)
        XCTAssertThrowsError(try progress.append(ids: [], total: nil)) { error in
            XCTAssertEqual(error as? NetdiskPaginationError, .incomplete)
        }
        XCTAssertEqual(progress.uniqueCount, 1)
        XCTAssertEqual(progress.expectedTotal, 2)
    }

    func testRepeatedPageWithoutNewEntriesCannotLoop() throws {
        for total: Int? in [nil, 3] {
            var progress = NetdiskPageProgress()
            _ = try progress.append(ids: ["a", "b"], total: total)
            XCTAssertThrowsError(try progress.append(ids: ["b", "a"], total: total)) { error in
                XCTAssertEqual(error as? NetdiskPaginationError, .repeatedPage)
            }
            XCTAssertEqual(progress.uniqueCount, 2)
        }
    }

    func testInvalidMetadataAndExcessEntriesCannotCountAsComplete() throws {
        for (ids, total): ([String], Int?) in [(["a"], -1), ([""], 1), ([" \n"], nil), (["a", "b"], 1)] {
            var progress = NetdiskPageProgress()
            XCTAssertThrowsError(try progress.append(ids: ids, total: total))
            XCTAssertEqual(progress.uniqueCount, 0)
            XCTAssertNil(progress.expectedTotal)
        }
    }

    func testEmptyDirectoryAndLateTotalAreSupported() throws {
        var empty = NetdiskPageProgress()
        XCTAssertTrue(try empty.append(ids: [], total: 0).isComplete)
        var progress = NetdiskPageProgress()
        XCTAssertFalse(try progress.append(ids: ["a"], total: nil).isComplete)
        XCTAssertTrue(try progress.append(ids: ["b"], total: 2).isComplete)
    }
}
