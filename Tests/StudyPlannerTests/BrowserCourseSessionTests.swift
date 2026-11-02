import XCTest
import WebKit
@testable import StudyPlanner

final class BrowserCourseSessionTests: XCTestCase {
    @MainActor
    private func page() async throws -> WebLessonReader {
        let reader = WebLessonReader(useExternalBrowser: false)
        reader.webView.loadHTMLString("<html><body>Browser bridge fixture</body></html>", baseURL: URL(string: "https://example.com/course"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("document.body?.textContent")) as? String == "Browser bridge fixture" { return reader }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw XCTSkip("WebKit fixture could not load in this environment")
    }

    @MainActor
    func testProductionReaderDoesNotCreateEmbeddedBrowser() {
        let reader = WebLessonReader()
        XCTAssertNil(reader.webView)
        reader.stop()
    }

    @MainActor
    func testBridgeRefusesAnotherOriginAndPreservesSameSession() async throws {
        let reader = try await page(); defer { reader.stop() }
        let rejected = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "one", origin: "https://other.example"))
        XCTAssertEqual(rejected as? String, "wrong-site")
        let observed1 = try await reader.webView.evaluateJavaScript("typeof window.__studyCourseBridge") as? String
        XCTAssertEqual(observed1, "undefined")
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "one", origin: "https://example.com"))
        _ = try await reader.webView.evaluateJavaScript("window.__studyCourseBridge.jobs.saved = {done:true}; true;")
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "one", origin: "https://example.com"))
        let observed2 = try await reader.webView.evaluateJavaScript("window.__studyCourseBridge.jobs.saved.done") as? Bool
        XCTAssertEqual(observed2, true)
    }

    @MainActor
    func testAsyncJobRoundTripAndStaleSessionIsolation() async throws {
        let reader = try await page(); defer { reader.stop() }
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "one", origin: "https://example.com"))
        let body = "await new Promise(r => setTimeout(r, 20)); return {title: '课程', force, index};"
        let accepted = try await reader.webView.evaluateJavaScript(BrowserCourseSession.jobScript(body: body,
            argumentsJSON: "{\"force\":true,\"index\":3}", id: "job", session: "one"))
        XCTAssertEqual(accepted as? String, "started")
        try await Task.sleep(for: .milliseconds(80))
        let value = try await reader.webView.evaluateJavaScript("window.__studyCourseBridge.jobs.job.value") as? [String: Any]
        XCTAssertEqual(value?["title"] as? String, "课程")
        XCTAssertEqual(value?["index"] as? Int, 3)
        XCTAssertEqual(value?["force"] as? Bool, true)
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "two", origin: "https://example.com"))
        let stale = try await reader.webView.evaluateJavaScript(BrowserCourseSession.jobScript(body: "window.unwanted = true;", argumentsJSON: "{}", id: "late", session: "one"))
        XCTAssertEqual(stale as? String, "changed")
        let observed3 = try await reader.webView.evaluateJavaScript("typeof window.unwanted") as? String
        XCTAssertEqual(observed3, "undefined")
    }

    @MainActor
    func testClosingRestoresOnlyHooksOwnedByBridge() async throws {
        let reader = try await page(); defer { reader.stop() }
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "one", origin: "https://example.com"))
        _ = try await reader.webView.evaluateJavaScript("""
        window.originalFetch = window.fetch;
        window.fetch = function fixture() {};
        window.__studyCourseBridge.fetch = window.fetch;
        window.__studyCourseBridge.stop(); true;
        """)
        let observed4 = try await reader.webView.evaluateJavaScript("window.fetch === window.originalFetch") as? Bool
        XCTAssertEqual(observed4, true)
        _ = try await reader.webView.evaluateJavaScript(BrowserCourseSession.bootstrap(session: "two", origin: "https://example.com"))
        _ = try await reader.webView.evaluateJavaScript("""
        window.__studyCourseBridge.fetch = window.fetch;
        window.newSiteFetch = function replacement() {};
        window.fetch = window.newSiteFetch;
        window.__studyCourseBridge.stop(); true;
        """)
        let observed5 = try await reader.webView.evaluateJavaScript("window.fetch === window.newSiteFetch") as? Bool
        XCTAssertEqual(observed5, true)
    }

    func testErrorMessagesDoNotExposeBrowserErrorDetails() {
        let error = NSError(domain: "fixture", code: 8, userInfo: [NSLocalizedDescriptionKey: "private page contents"])
        let message = BrowserCourseSession.failure(error, kind: .safari).localizedDescription
        XCTAssertFalse(message.contains("private page contents"))
        XCTAssertTrue(message.contains("JavaScript"))
        XCTAssertTrue(BrowserCourseSession.failure(NSError(domain: "fixture", code: -1743), kind: .chromium)
            .localizedDescription.contains("自动化"))
    }
}
