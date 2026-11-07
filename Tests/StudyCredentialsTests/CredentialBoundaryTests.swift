import XCTest
import Security
@testable import StudyCredentials

final class CredentialBoundaryTests: XCTestCase {
    func testOnlyKnownServicesAndAccountsAreAccepted() {
        for (service, account) in [("local.studyplanner.cloud", "server"), ("local.studyplanner.cloud", "ssh-server"),
            ("local.studyplanner.sync", "android"), ("local.studyplanner.website-account", "yantu"),
            ("local.studyplanner.website-account", "xuecheng"), ("local.studyplanner.assistant.sdk-v2", String(repeating: "a", count: 64))] {
            XCTAssertTrue(CredentialRequest(.load, service: service, account: account).isValid)
            XCTAssertFalse(CredentialRequest(.load, service: service, account: account + "unexpected").isValid)
        }
        XCTAssertFalse(CredentialRequest(.load, service: "unrelated.application", account: "password").isValid)
        XCTAssertFalse(CredentialRequest(.load, service: "local.studyplanner.assistant.sdk-v2", account: String(repeating: "z", count: 64)).isValid)
    }

    func testMalformedPayloadAndSecretBearingHandshakeAreRejectedBeforeAnyKeychainAccess() {
        let invalid = [CredentialRequest(.ping, service: "", account: "", value: Data([1])),
            CredentialRequest(.save, service: "local.studyplanner.cloud", account: "server"),
            CredentialRequest(.load, service: "local.studyplanner.cloud", account: "server", value: Data([1])),
            CredentialRequest(.save, service: "local.studyplanner.cloud", account: "server", value: Data(repeating: 1, count: 65_537))]
        for request in invalid {
            XCTAssertFalse(request.isValid)
            XCTAssertEqual(CredentialClient.perform(request).1, errSecParam)
            XCTAssertEqual(CredentialStore.perform(request).1, errSecParam)
        }
    }

    func testFixtureNamespaceOnlyAcceptsDisposableIDsAndKnownDummyValue() throws {
        let account = UUID().uuidString
        let request = CredentialRequest(.save, service: "local.studyplanner.credential-probe", account: account, value: CredentialRequest.fixture, interactive: false)
        XCTAssertTrue(request.isValid)
        let decoded = try JSONDecoder().decode(CredentialRequest.self, from: JSONEncoder().encode(request))
        XCTAssertFalse(decoded.interactive)
        XCTAssertEqual(decoded.value, CredentialRequest.fixture)
        XCTAssertFalse(CredentialRequest(.save, service: request.service, account: account, value: Data("other-content".utf8)).isValid)
        XCTAssertFalse(CredentialRequest(.load, service: request.service, account: "real-account").isValid)
    }
}
