import XCTest
@testable import StudyPersistence

final class BoundedFileDataTests: XCTestCase {
    func testActualReadLimitAndBinaryRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data(repeating: 0xff, count: 200_000)
        try bytes.write(to: url)
        XCTAssertEqual(try BoundedFileData.read(url, limit: bytes.count), bytes)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        XCTAssertThrowsError(try BoundedFileData.read(from: file, limit: 65_536))
        XCTAssertEqual(try file.offset(), 65_537)
        XCTAssertEqual(try file.read(upToCount: 1), Data([0xff]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testInvalidLimitsDoNotReadAndEmptyFileAcceptsZeroLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        for limit in [-1, Int.max] { XCTAssertThrowsError(try BoundedFileData.read(from: file, limit: limit)) }
        XCTAssertEqual(try file.offset(), 0)
        XCTAssertEqual(try BoundedFileData.read(url, limit: 0), Data())
    }
}
