import XCTest
import StudyCore
@testable import StudyPlanner

private actor ReaderTransport: NetdiskTransport {
    private var fails = false
    private var holdNext = false
    private var heldError: NetdiskAPIError?
    private var held: CheckedContinuation<Void, Never>?

    func fail(_ value: Bool) { fails = value }
    func hold(error: NetdiskAPIError? = nil) { holdNext = true; heldError = error }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }

    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        if holdNext {
            holdNext = false
            let error = heldError
            heldError = nil
            await withCheckedContinuation { held = $0 }
            if let error { throw error }
        }
        if fails { throw NetdiskAPIError.wrongPasscode }
        return Data(#"{"code":0,"data":{"stoken":"synthetic","title":"课程","passcode":"0"}}"#.utf8)
    }

    func get(path: String, query: [String: String]) async throws -> Data {
        let entries: [[String: Any]] = (1...3).map { index in
            ["fid": "video\(index)", "file_name": "第\(index)讲.mp4", "dir": false,
             "file_type": 1, "category": 1, "size": 100_000_000, "duration": 600, "status": 1]
        }
        return try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["list": entries],
            "metadata": ["_count": 3, "_page": 1]])
    }
}

final class NetdiskImportReaderTests: XCTestCase {
    private let link = NetdiskLink(pwdID: "abc123", fragmentFID: nil, inAppPasscode: nil)

    @MainActor
    private func finish(_ reader: NetdiskImportReader) async throws {
        for _ in 0..<500 {
            if !reader.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader did not finish the synthetic request")
    }

    @MainActor
    func testFailedRefreshCannotReusePreviousImportResult() async throws {
        let transport = ReaderTransport(), reader = NetdiskImportReader(directTransport: transport)
        defer { reader.stop() }
        reader.startRead(link)
        try await finish(reader)
        XCTAssertEqual(reader.result?.courses.count, 1)
        await transport.fail(true)
        reader.refresh()
        XCTAssertNil(reader.result, "Starting a new read invalidates the previous import result immediately")
        try await finish(reader)
        XCTAssertNil(reader.result)
        XCTAssertTrue(reader.status.contains("读取失败"))
        await transport.fail(false)
        reader.refresh()
        try await finish(reader)
        XCTAssertEqual(reader.result?.courses.count, 1)
        XCTAssertTrue(reader.status.contains("读取完成"))
    }

    @MainActor
    func testInvalidNewAddressClearsPreviousResultAndStopsLoading() async throws {
        let reader = NetdiskImportReader(directTransport: ReaderTransport())
        defer { reader.stop() }
        reader.startRead(link)
        try await finish(reader)
        XCTAssertNotNil(reader.result)
        reader.address = "not a valid share"
        reader.load()
        XCTAssertNil(reader.result)
        XCTAssertFalse(reader.busy)
        XCTAssertEqual(reader.status, NetdiskAPIError.badLink.localizedDescription)
    }

    @MainActor
    func testSupersededReadCannotReplaceTheNewShare() async throws {
        let transport = ReaderTransport(), reader = NetdiskImportReader(directTransport: transport)
        defer { reader.stop() }
        await transport.hold(error: .notLoggedIn("superseded request"))
        reader.startRead(link)
        for _ in 0..<500 {
            if await transport.isHeld() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await transport.isHeld()
        XCTAssertTrue(held)
        reader.startRead(.init(pwdID: "def456", fragmentFID: nil, inAppPasscode: nil))
        try await finish(reader)
        XCTAssertEqual(reader.result?.scan.pwdID, "def456")
        await transport.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(reader.result?.scan.pwdID, "def456")
        XCTAssertFalse(reader.busy)
        XCTAssertTrue(reader.status.contains("读取完成"))
        reader.stop()
        XCTAssertNil(reader.result)
    }
}
