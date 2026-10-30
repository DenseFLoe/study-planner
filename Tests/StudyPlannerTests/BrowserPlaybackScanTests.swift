import XCTest
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif
@testable import StudyPlanner

final class BrowserPlaybackScanTests: XCTestCase {
    func testPausedMediaSurvivesUnreadableTabsInEitherOrder() {
        for states in [["stopped", "unknown", "empty"], ["unknown", "empty", "stopped"]] {
            var scan = BrowserPlaybackScan()
            for state in states { scan.record(state) }
            guard case .stopped = scan.observation else { return XCTFail("A readable pause must not become unavailable") }
        }
    }

    func testPausedMediaSurvivesOtherWindowOrTabErrors() {
        for failsFirst in [true, false] {
            var scan = BrowserPlaybackScan()
            if failsFirst { scan.recordFailure(.unavailable("受限标签页")) }
            scan.record("stopped")
            if !failsFirst { scan.recordFailure(.unavailable("受限标签页")) }
            guard case .stopped = scan.observation else { return XCTFail("Unrelated read failures must not hide a pause") }
        }
    }

    func testPlayingMediaWinsOverPausedAndUnreadableTabs() {
        for states in [["playing", "stopped", "unknown"], ["unknown", "stopped", "playing"]] {
            var scan = BrowserPlaybackScan()
            for state in states { scan.record(state) }
            guard case .playing = scan.observation else { return XCTFail("Any readable playing media keeps supervision satisfied") }
        }
    }

    func testUnreadablePagesWithoutMediaRemainUnavailable() {
        for state: String? in ["unknown", nil, "unexpected"] {
            var scan = BrowserPlaybackScan()
            scan.record("empty")
            scan.record(state)
            guard case .unavailable = scan.observation else { return XCTFail("Unreadable media is not a pause") }
        }
        var scan = BrowserPlaybackScan()
        scan.recordFailure(.unavailable("自动化权限已撤销"))
        scan.recordFailure(.unavailable("后续错误"))
        XCTAssertEqual(scan.observation, .unavailable("自动化权限已撤销"))
    }

    func testReadableEmptyBrowserIsStopped() {
        var scan = BrowserPlaybackScan()
        XCTAssertEqual(scan.observation, .stopped("浏览器没有正在播放的音视频"))
        scan.record("empty")
        XCTAssertEqual(scan.observation, .stopped("浏览器没有正在播放的音视频"))
    }

    #if canImport(JavaScriptCore)
    func testProductionScriptRecognizesPauseWithCrossOriginFrameAndResume() throws {
        let context = try makeContext()
        context.evaluateScript("document = doc([media(true)], [blockedFrame(), {contentDocument: null}]);")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "stopped")
        context.evaluateScript("document.media[0].paused = false;")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "playing")
        context.evaluateScript("document.media[0].paused = true;")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "stopped")
        XCTAssertNil(context.exception)
    }

    func testProductionScriptRecognizesSameOriginNestedPauseWithBlockedSibling() throws {
        let context = try makeContext()
        context.evaluateScript("document = doc([], [blockedFrame(), {contentDocument: doc([media(true)], [])}]);")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "stopped")
        XCTAssertNil(context.exception)
    }

    func testProductionScriptDoesNotInferPauseFromCrossOriginOnlyPlayer() throws {
        let context = try makeContext()
        context.evaluateScript("document = doc([], [blockedFrame()]);")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "unknown")
        context.evaluateScript("document = doc([], []);")
        XCTAssertEqual(context.evaluateScript(BrowserPlaybackScan.mediaScript)?.toString(), "empty")
        XCTAssertNil(context.exception)
    }

    private func makeContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(#"""
        function media(paused) {
          return {paused, ended: false, seeking: false, readyState: 4, playbackRate: 1};
        }
        function doc(media, frames) {
          return {media, querySelectorAll(selector) { return selector === 'video,audio' ? media : frames; }};
        }
        function blockedFrame() {
          return {get contentDocument() { throw new Error('cross-origin'); }};
        }
        """#)
        XCTAssertNil(context.exception)
        return context
    }
    #endif
}
