import XCTest
@testable import StudyCore

final class BoundedUTF8FileTests: XCTestCase {
    private func withFile(_ data: Data, _ check: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic-input.txt")
        try data.write(to: file)
        try check(file)
        XCTAssertEqual(try Data(contentsOf: file), data, "Reading must never rewrite the selected file")
    }
    func testUTF8ByteBoundaryAndEmptyFile() throws {
        let text = String(repeating: "密钥", count: 100), data = Data(text.utf8)
        try withFile(data) { file in
            XCTAssertEqual(try BoundedUTF8File.read(file, maximumBytes: data.count), text)
            XCTAssertThrowsError(try BoundedUTF8File.read(file, maximumBytes: data.count - 1)) {
                guard case BoundedTextFileError.tooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        try withFile(Data()) { XCTAssertEqual(try BoundedUTF8File.read($0, maximumBytes: 0), "") }
    }
    func testLargeFileReadsOnlyOneByteBeyondTheLimit() throws {
        try withFile(Data(repeating: 65, count: 100_000)) { url in
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            XCTAssertThrowsError(try BoundedUTF8File.read(from: file, maximumBytes: 65536))
            XCTAssertEqual(try file.offset(), 65537)
        }
    }
    func testInvalidUTF8AndInvalidLimitsAreRejected() throws {
        try withFile(Data([0x41, 0xff, 0x42])) { url in
            XCTAssertThrowsError(try BoundedUTF8File.read(url, maximumBytes: 3)) {
                guard case BoundedTextFileError.invalidUTF8 = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            XCTAssertThrowsError(try BoundedUTF8File.read(from: file, maximumBytes: -1))
            XCTAssertThrowsError(try BoundedUTF8File.read(from: file, maximumBytes: Int.max))
            XCTAssertEqual(try file.offset(), 0)
        }
    }
}
