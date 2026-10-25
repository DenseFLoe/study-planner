import XCTest
import Foundation
@testable import StudySync

final class CloudSSHTests: XCTestCase, @unchecked Sendable {
    private var pin: String { "SHA256:" + Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    private var placeholderKey: String { "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nEXAMPLE_PLACEHOLDER\n-----END OPENSSH " + "PRIVATE KEY-----" }
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
