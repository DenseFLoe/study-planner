import XCTest
import Foundation
@testable import StudySync

final class SyncTransferTests: XCTestCase, @unchecked Sendable {
    func testLargeRoundTripThroughJavaTransferEngine() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let classes = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: classes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: classes) }
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        let jar = root.appendingPathComponent("Android/tools/json.jar").path
        try run("/usr/bin/javac", ["-cp", jar, "-d", classes.path,
                root.appendingPathComponent("Android/src/local/studyplanner/SyncTransfer.java").path,
                root.appendingPathComponent("Android/tests/SyncTransferTests.java").path])
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/java")
        process.arguments = ["-cp", jar + ":" + classes.path, "local.studyplanner.SyncTransferTests", "bridge"]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
        // The JSON and its reply each exceed the previous whole-message limit.
        let payload = try JSONSerialization.data(withJSONObject: ["blob": String(repeating: "测/试", count: 3_000_000)])
        XCTAssertGreaterThan(payload.count, 16 * 1024 * 1024)
        let response = try await SyncTransfer.exchange(payload, post: { request in
            XCTAssertLessThan(request.count, 16 * 1024 * 1024)
            try input.fileHandleForWriting.write(contentsOf: request + Data([10]))
            var reply = Data()
            while reply.last != 10 {
                let part = output.fileHandleForReading.availableData
                guard !part.isEmpty else { throw ClientError.message("Java bridge ended early") }
                reply.append(part)
            }
            XCTAssertLessThan(reply.count, 16 * 1024 * 1024)
            return reply
        }, progress: { _ in })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: response) as? [String: String],
                       try JSONSerialization.jsonObject(with: payload) as? [String: String])
    }

    func testInvalidAcknowledgementStopsBeforeExchange() async throws {
        var calls = 0
        do {
            _ = try await SyncTransfer.exchange(Data("{}".utf8), post: { _ in
                calls += 1
                return Data((calls == 1 ? #"{"transfer":1}"# : #"{"offset":0}"#).utf8)
            }, progress: { _ in })
            XCTFail("Invalid acknowledgement accepted")
        } catch { XCTAssertEqual(calls, 2) }
    }

    func testEmptyDownloadChunkIsRejected() async throws {
        var calls = 0
        do {
            _ = try await SyncTransfer.exchange(Data("{}".utf8), post: { _ in
                calls += 1
                return Data([#"{"transfer":1}"#, #"{"offset":2}"#, #"{"length":10}"#, #"{"data":""}"#][calls - 1].utf8)
            }, progress: { _ in })
            XCTFail("Empty chunk accepted")
        } catch { XCTAssertEqual(calls, 4) }
    }
}
