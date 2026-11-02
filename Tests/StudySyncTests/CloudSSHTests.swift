import XCTest
import Foundation
import Darwin
@testable import StudySync

/// Model the observed Foundation failure: the child exits, but its run-loop
/// based wait never returns. Release the injected stall when the test ends.
private final class StalledExitWaitProcess: Process, @unchecked Sendable {
    let child: Process
    let releaseWait = DispatchSemaphore(value: 0)
    init(child: Process) { self.child = child; super.init() }
    override var isRunning: Bool { child.isRunning }
    override var processIdentifier: Int32 { child.processIdentifier }
    override func terminate() { child.terminate() }
    override func waitUntilExit() { releaseWait.wait() }
}

final class CloudSSHTests: XCTestCase, @unchecked Sendable {
    private var pin: String { "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    private var placeholderKey: String { "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nEXAMPLE_PLACEHOLDER\n-----END OPENSSH " + "PRIVATE KEY-----" }

    private func launchOnTemporaryThread(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread {
                do { try process.run(); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }.start()
        }
    }

    private func fixture() throws -> (Process, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-cleanup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("EXAMPLE_PLACEHOLDER".utf8).write(to: directory.appendingPathComponent("identity"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return (process, directory)
    }

    private func assertCloseFinishes(_ tunnel: CloudSSHTunnel, process: Process, directory: URL) async {
        let finished = expectation(description: "SSH cleanup returns on another thread")
        DispatchQueue.global().async {
            tunnel.close()
            tunnel.close() // Explicit cleanup followed by deinit must be harmless.
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Temporary credentials must be removed")
    }

    func testTunnelCleanupReturnsAfterLaunchThreadExits() async throws {
        let (process, directory) = try fixture()
        defer { CloudSSHProcess.stop(process); try? FileManager.default.removeItem(at: directory) }
        try await launchOnTemporaryThread(process)
        let tunnel = CloudSSHTunnel(process: process, directory: directory, port: 1)
        await assertCloseFinishes(tunnel, process: process, directory: directory)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testTunnelCleanupDoesNotDependOnUnresponsiveExitWaiter() async throws {
        let (process, directory) = try fixture()
        let stalled = StalledExitWaitProcess(child: process)
        defer {
            stalled.releaseWait.signal()
            CloudSSHProcess.stop(process)
            try? FileManager.default.removeItem(at: directory)
        }
        try await launchOnTemporaryThread(process)
        let tunnel = CloudSSHTunnel(process: stalled, directory: directory, port: 1)
        await assertCloseFinishes(tunnel, process: process, directory: directory)
    }

    func testTunnelCleanupKillsChildThatIgnoresTermination() async throws {
        let (process, directory) = try fixture()
        defer { CloudSSHProcess.stop(process); try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The ignored signal disposition survives exec; no grandchild is left behind.
        process.arguments = ["-c", "trap '' TERM; printf ready > \"$1\"; exec /bin/sleep 30", "ssh-fixture", ready.path]
        try await launchOnTemporaryThread(process)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: ready.path), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let tunnel = CloudSSHTunnel(process: process, directory: directory, port: 1)
        await assertCloseFinishes(tunnel, process: process, directory: directory)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testExitWaitTimesOutWithoutStoppingChild() async throws {
        let (process, directory) = try fixture()
        defer { CloudSSHProcess.stop(process); try? FileManager.default.removeItem(at: directory) }
        try await launchOnTemporaryThread(process)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(CloudSSHProcess.waitForExit(process, timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(process.isRunning)
    }

    func testTunnelCleanupAfterChildAlreadyExited() async throws {
        let (process, directory) = try fixture()
        defer { CloudSSHProcess.stop(process); try? FileManager.default.removeItem(at: directory) }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.arguments = []
        try await launchOnTemporaryThread(process)
        XCTAssertTrue(CloudSSHProcess.waitForExit(process, timeout: 3))
        let tunnel = CloudSSHTunnel(process: process, directory: directory, port: 1)
        await assertCloseFinishes(tunnel, process: process, directory: directory)
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testLegacyHTTPSCredentialsStillDecodeAndValidate() throws {
        let saved = try JSONSerialization.data(withJSONObject: ["endpoint": "https://fixture.example", "token": String(repeating: "x", count: 32)])
        let credentials = try JSONDecoder().decode(CloudCredentials.self, from: saved)
        XCTAssertEqual(credentials.method, .https)
        XCTAssertEqual(try credentials.validated().endpoint, "https://fixture.example")
        XCTAssertThrowsError(try CloudCredentials(endpoint: "http://127.0.0.1:18090", token: credentials.token))
    }
    func testSSHRejectsShellArgumentsURLsAndUntrustedFingerprints() throws {
        for host in ["-oProxyCommand=example", "https://fixture.example", "user@fixture.example", "fixture.example/path", "fixture.example\nother"] {
            XCTAssertThrowsError(try CloudSSHConfiguration(host: host, username: "example_user", fingerprint: pin, privateKey: placeholderKey))
        }
        XCTAssertThrowsError(try CloudSSHConfiguration(host: "fixture.example", port: 0, username: "example_user", fingerprint: pin, privateKey: placeholderKey))
        XCTAssertThrowsError(try CloudSSHConfiguration(host: "fixture.example", username: "example_user", fingerprint: "", privateKey: placeholderKey))
        XCTAssertThrowsError(try CloudSSHConfiguration(host: "fixture.example", username: "-invalid", fingerprint: pin, privateKey: placeholderKey))
        let ssh = try CloudSSHConfiguration(host: "2001:db8::1", port: 2222, username: "example_user", fingerprint: pin, privateKey: placeholderKey)
        XCTAssertEqual(ssh.identity, "ssh://example_user@[2001:db8::1]:2222/127.0.0.1:18090")
        let credentials = try CloudCredentials(ssh: ssh, token: String(repeating: "x", count: 32))
        XCTAssertEqual(try JSONDecoder().decode(CloudCredentials.self, from: JSONEncoder().encode(credentials)).validated().method, .ssh)
    }
    func testLiveSSHPinAndForwardingWithoutReadingScheduleData() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["STUDY_SSH_TEST_HOST"], let user = env["STUDY_SSH_TEST_USER"],
              let keyPath = env["STUDY_SSH_TEST_KEY_PATH"], let fingerprint = env["STUDY_SSH_TEST_FINGERPRINT"] else {
            throw XCTSkip("Explicit SSH fixture environment was not supplied")
        }
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let ssh = try CloudSSHConfiguration(host: host, port: Int(env["STUDY_SSH_TEST_PORT"] ?? "22")!, username: user, fingerprint: fingerprint, privateKey: key)
        let tunnel = try await CloudSSHTunnel.open(ssh)
        let endpoint = tunnel.endpoint
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: endpoint + "/cloud/status")!)
        request.timeoutInterval = 5; request.setValue("close", forHTTPHeaderField: "Connection")
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, "Unauthenticated probe must reach the service without reading schedule data")
        session.invalidateAndCancel(); tunnel.close()
        let closedSession = URLSession(configuration: .ephemeral); defer { closedSession.invalidateAndCancel() }
        do { _ = try await closedSession.data(for: request); XCTFail("forwarding listener must close after sync") } catch {}
        let wrong = try CloudSSHConfiguration(host: host, port: ssh.port, username: user, fingerprint: pin, privateKey: key)
        do { let rejected = try await CloudSSHTunnel.open(wrong); rejected.close(); XCTFail("wrong host pin must reject before authentication") } catch {}
    }
}
