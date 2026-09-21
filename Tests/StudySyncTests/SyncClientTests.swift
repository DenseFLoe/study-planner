import XCTest
import Foundation
import StudyCore
import StudyPersistence
@testable import StudySync

private final class MemoryVault: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Pairing?
    func load() -> Pairing? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ next: Pairing) { lock.lock(); value = next; lock.unlock() }
}
final class SyncClientTests: XCTestCase, @unchecked Sendable {
    func testPrivateGatewayFilter() {
        XCTAssertTrue(SyncClient.isPrivateIPv4("192.168.43.1"))
        XCTAssertTrue(SyncClient.isPrivateIPv4("172.20.10.1"))
        XCTAssertFalse(SyncClient.isPrivateIPv4("8.8.8.8"))
        XCTAssertFalse(SyncClient.isPrivateIPv4("127.0.0.1"))
        XCTAssertFalse(SyncClient.isPrivateIPv4("192.168.1.1/path"))
    }
    func testPairingRequestRoundTripAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let request = PairingRequest(secret: String(repeating: "a1", count: 32), expiresAt: now.addingTimeInterval(300))
        XCTAssertEqual(PairingRequest.parse(request.payload, now: now), request)
        XCTAssertNil(PairingRequest.parse(request.payload, now: now.addingTimeInterval(301)))
        XCTAssertNil(PairingRequest.parse("https://example.com/?secret=" + request.secret, now: now))
        XCTAssertNil(PairingRequest.parse("studyplanner://pair?v=2&secret=short&expires=2000000300", now: now))
    }
    func testPairingRequestUsesSecureRandomSecret() throws {
        let first = try SyncClient.makePairingRequest()
        let second = try SyncClient.makePairingRequest()
        XCTAssertEqual(first.secret.count, 64)
        XCTAssertTrue(first.secret.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(first.secret, second.secret)
        XCTAssertEqual(PairingRequest.parse(first.payload)?.secret, first.secret)
    }
    func testMacClientAgainstAndroidEmulator() async throws {
        guard ProcessInfo.processInfo.environment["STUDY_SYNC_DEVICE_TEST"] == "1" else { throw XCTSkip("Requires isolated Android bridge instrumentation and ADB forwarding") }
        let pair = try String(contentsOfFile: "/tmp/study-sync-pairing.txt", encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("planner.store"), vault = MemoryVault()
        let environment = SyncEnvironment(databaseURL: url, loadPairing: { vault.load() }, savePairing: { vault.save($0) }, acceptsHost: { $0 == "127.0.0.1" }, gateway: { "127.0.0.1" })
        let courseID = UUID()
        try await Task.detached {
            let db = try LocalRepository(url: url); var state = PlannerState(); state.settings.availability = []
            var course = Course(name: "Mac HTTPS 联调", totalMinutes: 30, startDate: Date(), deadline: Date()); course.id = courseID; course.autoScheduleEnabled = false
            state.courses.append(course); try db.save(state)
        }.value
        let result = try await SyncClient.run(automatic: true, host: "127.0.0.1", pairingText: pair, environment: environment, log: { _ in })
        let outcome = try XCTUnwrap(result)
        XCTAssertEqual(outcome.state.courses.count, 2)
        XCTAssertTrue(outcome.state.courses.contains { $0.id == courseID })
        XCTAssertEqual(outcome.ledger.lastAutoDate, SyncLedger.day(Date()))
        XCTAssertNotNil(vault.load())
        // Service is now closed: success here proves the persistent gate skips networking.
        let skipped = try await SyncClient.run(automatic: true, environment: environment, log: { _ in XCTFail("Already successful automatic sync must not start networking") })
        XCTAssertNil(skipped)
    }
}

extension SyncClientTests {
    func testActionablePairingAndConnectionErrors() {
        let closed = SyncDiagnostic.response(status: 400, body: Data(#"{"code":"pairing_closed"}"#.utf8), phase: "首次配对")
        XCTAssertTrue(closed.localizedDescription.contains("没有有效配对窗口"))
        let oldServer = SyncDiagnostic.response(status: 400, body: Data(#"{"error":"请求失败或认证无效"}"#.utf8), phase: "首次配对")
        XCTAssertTrue(oldServer.localizedDescription.contains("重新生成二维码"))
        let unauthorized = SyncDiagnostic.response(status: 401, body: Data(#"{"code":"unauthorized"}"#.utf8), phase: "交换日程")
        XCTAssertTrue(unauthorized.localizedDescription.contains("凭据已失效"))
        let refused = SyncDiagnostic.transport(URLError(.cannotConnectToHost), phase: "首次配对", address: "192.168.43.1")
        XCTAssertTrue(refused.localizedDescription.contains("192.168.43.1:8765"))
        XCTAssertTrue(refused.localizedDescription.contains("-1004"))
    }
}
