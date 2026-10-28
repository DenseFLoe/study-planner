import XCTest
@testable import StudyPlanner

// No shared mutable test state; Swift 6 XCTest discovery transfers the instance
// into async wrappers even though every test runs on the main actor.
@MainActor final class PlaybackDetectionTests: XCTestCase, @unchecked Sendable {
    func testAutomationStatusPreservesFailureReason() async {
        XCTAssertEqual(PlaybackAutomationPermission(status: 0), .granted)
        XCTAssertEqual(PlaybackAutomationPermission(status: -1743), .denied)
        XCTAssertEqual(PlaybackAutomationPermission(status: -1744), .consentRequired)
        XCTAssertEqual(PlaybackAutomationPermission(status: -600), .notRunning)
        XCTAssertEqual(PlaybackAutomationPermission(status: -50), .failed(-50))
        XCTAssertNil(PlaybackAutomationPermission.granted.message(for: "Safari"))
        XCTAssertTrue(PlaybackAutomationPermission.denied.message(for: "Safari")!.contains("隐私与安全性 → 自动化"))
        XCTAssertTrue(PlaybackAutomationPermission.consentRequired.message(for: "Safari")!.contains("系统弹窗"))
        XCTAssertTrue(PlaybackAutomationPermission.failed(-50).message(for: "Safari")!.contains("-50"))
    }

    func testSafariEditionsUseSafariScripting() async {
        for bundleID in ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] {
            let app = SupervisedApplication(bundleID: bundleID, name: "Safari", path: "/missing.app")
            XCTAssertEqual(app.scripting, .safari)
        }
    }

    func testFailedAuthorizationDoesNotReadOrRequestAudio() async {
        for permission in [PlaybackAutomationPermission.denied, .consentRequired, .notRunning, .failed(-50)] {
            var calls: [String] = []
            let result = await PlaybackDetection.check(kind: .safari, name: "Safari",
                requestAutomation: { calls.append("authorize"); return permission },
                readScripted: { calls.append("script"); return .stopped("empty") },
                readAudio: { calls.append("audio"); return .playing("unrelated audio") })
            XCTAssertEqual(calls, ["authorize"])
            XCTAssertEqual(result, .unavailable(permission.message(for: "Safari")!))
        }
    }

    func testGrantedAuthorizationReadsSafariWithoutAudio() async {
        var calls: [String] = []
        let result = await PlaybackDetection.check(kind: .safari, name: "Safari",
            requestAutomation: { calls.append("authorize"); return .granted },
            readScripted: { calls.append("script"); return .playing("video") },
            readAudio: { calls.append("audio"); return .unavailable("no permission") })
        XCTAssertEqual(calls, ["authorize", "script"])
        XCTAssertEqual(result, .playing("video"))
    }

    func testSafariJavaScriptSwitchIsNotReplacedByAudioPermissionError() async {
        let failure = PlaybackDetection.scriptFailure(code: 8, kind: .safari, name: "Safari", executingJavaScript: true)
        var audioRequested = false
        let result = await PlaybackDetection.check(kind: .safari, name: "Safari",
            requestAutomation: { .granted }, readScripted: { failure },
            readAudio: { audioRequested = true; return .unavailable("请允许录制系统音频") })
        XCTAssertFalse(audioRequested)
        XCTAssertEqual(result, .unavailable(PlaybackDetection.safariJavaScriptHelp))
    }

    func testBackgroundSafariFailureNeverUsesPreviouslyAuthorizedAudio() async {
        let failures: [PlaybackObservation?] = [
            .unavailable("自动化权限已撤销"), .unavailable("跨域播放器不可读"),
            .unavailable("超时"), nil
        ]
        for failure in failures {
            var audioRead = false
            let result = await PlaybackDetection.check(kind: .safari, name: "Safari",
                readScripted: { failure },
                readAudio: { audioRead = true; return .stopped("no attributable processes") })
            XCTAssertFalse(audioRead)
            guard case .unavailable = result else { return XCTFail("Unavailable Safari must not be marked stopped") }
            if let failure { XCTAssertEqual(result, failure) }
        }
    }

    func testReliableScriptedStopDoesNotUseAudioFallback() async {
        for kind in [PlaybackScripting.safari, .chromium, .quickTime, .playerState] {
            var audioRead = false
            let result = await PlaybackDetection.check(kind: kind, name: "Player",
                readScripted: { .stopped("paused") },
                readAudio: { audioRead = true; return .playing("audio") })
            XCTAssertFalse(audioRead)
            XCTAssertEqual(result, .stopped("paused"))
        }
    }

    func testOtherScriptableAppsCanStillUseAudioFallback() async {
        for kind in [PlaybackScripting.chromium, .quickTime, .playerState] {
            var audioRead = false
            let result = await PlaybackDetection.check(kind: kind, name: "Player",
                readScripted: { .unavailable("unreadable") },
                readAudio: { audioRead = true; return .playing("verified audio") })
            XCTAssertTrue(audioRead)
            XCTAssertEqual(result, .playing("verified audio"))
        }
    }

    func testFailedFallbackRetainsBothDiagnostics() async {
        let result = await PlaybackDetection.check(kind: .chromium, name: "Browser",
            readScripted: { .unavailable("script failed") },
            readAudio: { .unavailable("audio unavailable") })
        XCTAssertEqual(result, .unavailable("script failed audio unavailable"))
    }

    func testNonScriptableAppDoesNotRequestAutomation() async {
        var automationRequested = false
        let result = await PlaybackDetection.check(kind: nil, name: "Player",
            requestAutomation: { automationRequested = true; return .denied },
            readScripted: { nil }, readAudio: { .playing("audio") })
        XCTAssertFalse(automationRequested)
        XCTAssertEqual(result, .playing("audio"))
    }

    func testSafariErrorEightOnlyMeansJavaScriptSwitchDuringJavaScriptExecution() async {
        let switchError = PlaybackObservation.unavailable(PlaybackDetection.safariJavaScriptHelp)
        XCTAssertEqual(PlaybackDetection.scriptFailure(code: 8, kind: .safari, name: "Safari", executingJavaScript: true), switchError)
        XCTAssertNotEqual(PlaybackDetection.scriptFailure(code: 8, kind: .safari, name: "Safari"), switchError)
        XCTAssertNotEqual(PlaybackDetection.scriptFailure(code: 8, kind: .chromium, name: "Chrome", executingJavaScript: true), switchError)
    }

    func testRuntimePermissionErrorsUseTheSameRecoveryAsPreflight() async {
        for status: Int32 in [-1743, -1744, -600] {
            XCTAssertEqual(PlaybackDetection.scriptFailure(code: Int(status), kind: .safari, name: "Safari", executingJavaScript: true),
                           .unavailable(PlaybackAutomationPermission(status: status).message(for: "Safari")!))
        }
    }

    func testTimeoutAndUnknownErrorsAreNotMisreportedAsPermissionDenial() async {
        let timeout = PlaybackDetection.scriptFailure(code: -1712, kind: .safari, name: "Safari", executingJavaScript: true)
        guard case .unavailable(let detail) = timeout else { return XCTFail("Expected unavailable") }
        XCTAssertTrue(detail.contains("响应超时"))
        XCTAssertFalse(detail.contains("请到“系统设置"))
        let unknown = PlaybackDetection.scriptFailure(code: -1708, kind: .safari, name: "Safari")
        guard case .unavailable(let unknownDetail) = unknown else { return XCTFail("Expected unavailable") }
        XCTAssertTrue(unknownDetail.contains("-1708"))
        XCTAssertFalse(unknownDetail.contains("JavaScript"))
    }
}
