import XCTest
import WebKit
@testable import StudyPlanner

final class BrowserReplayTests: XCTestCase {
    @MainActor
    private func load(_ reader: WebLessonReader, url: URL, body: String) async throws {
        let documentID = UUID().uuidString
        reader.webView.loadHTMLString("""
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'"></head>
        <body>\(body)<div id="fixture-ready" data-document="\(documentID)"></div></body></html>
        """, baseURL: url)
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("location.href === \(BrowserCourseSession.literal(url.absoluteString)) && document.readyState === 'complete' && document.getElementById('fixture-ready')?.dataset.document === \(BrowserCourseSession.literal(documentID))")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Replay fixture did not load")
    }

    @MainActor
    private func probe(_ reader: WebLessonReader, url: URL) async throws -> [String: Any] {
        let value = try await reader.webView.evaluateJavaScript(BrowserCourseSession.replayProbe(
            documentURL: url, marker: "fixture-owner", script: WebLessonReader.replayScript))
        let text = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @MainActor
    func testWaitsForDocumentThenReadsRedirectedReplayAndReinstallsAfterReload() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let callback = URL(string: "https://view.csslcloud.net/api/view/callback?recordid=fixture")!
        let destination = URL(string: "https://view.csslcloud.net/replay/fixture?redirected=1")!
        XCTAssertTrue(BrowserCourseSession.isReplayPage(callback))
        XCTAssertTrue(BrowserCourseSession.isReplayPage(destination))
        try await load(reader, url: destination, body: "<div>第一节</div><div>直播时间：2026-07-29 14:00-15:00</div>")
        // Safari's URL property can already name the new destination while JavaScript
        // still executes in the previous document. Do not install in that document.
        let mismatched = try await probe(reader, url: callback)
        XCTAssertTrue(mismatched.isEmpty)
        _ = try await reader.webView.evaluateJavaScript("Object.defineProperty(document, 'readyState', {configurable:true, value:'loading'}); true;")
        let loading = try await probe(reader, url: destination)
        XCTAssertTrue(loading.isEmpty)
        let installedEarly = try await reader.webView.evaluateJavaScript("typeof window.__studyReplayReader") as? String
        XCTAssertEqual(installedEarly, "undefined")
        _ = try await reader.webView.evaluateJavaScript("Object.defineProperty(document, 'readyState', {configurable:true, value:'interactive'}); true;")
        let first = try await probe(reader, url: destination)
        XCTAssertEqual((first["metadata"] as? [String: Any])?["durationSeconds"] as? Int, 3600)

        // A new document at the same URL must install a new observer, even after
        // the previous document already returned metadata.
        try await load(reader, url: destination, body: "<div>第二节</div><div>直播时间：2026-07-29 14:00-15:30</div>")
        let second = try await probe(reader, url: destination)
        let metadata = try XCTUnwrap(second["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["title"] as? String, "第二节")
        XCTAssertEqual(metadata["durationSeconds"] as? Int, 5400)
        XCTAssertEqual(Set(metadata.keys), Set(["title", "durationSeconds", "watchedPercent"]))
    }

    @MainActor
    func testObserverCollectsMetadataAddedAfterInitialLoad() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://view.csslcloud.net/replay/fixture")!
        try await load(reader, url: url, body: "")
        let empty = try await probe(reader, url: url)
        XCTAssertTrue(empty["metadata"] is NSNull)
        _ = try await reader.webView.evaluateJavaScript("document.body.innerHTML = '<div>异步课节</div><div>直播时间：2026-07-29 14:00-15:00</div>'; true;")
        let filled = try await probe(reader, url: url)
        XCTAssertEqual((filled["metadata"] as? [String: Any])?["title"] as? String, "异步课节")
    }

    @MainActor
    func testWrapperWaitsForPopulatedFrameAndIgnoresUntrustedFrames() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://www.ixuecheng.cn/backWindow?url=PLACEHOLDER")!
        try await load(reader, url: url, body: """
        <iframe src="https://view.csslcloud.net.evil.example/api/view/callback?recordid=fixture"></iframe>
        <iframe src="https://view.csslcloud.net:9443/api/view/callback?recordid=fixture"></iframe>
        <iframe id="replay" src="https://view.csslcloud.net/api/view/callback?"></iframe>
        """)
        let empty = try await probe(reader, url: url)
        XCTAssertNil(empty["frame"])
        _ = try await reader.webView.evaluateJavaScript("document.getElementById('replay').src = 'https://view.csslcloud.net/api/view/callback?recordid=fixture'; true;")
        let populated = try await probe(reader, url: url)
        XCTAssertEqual(populated["frame"] as? String, "https://view.csslcloud.net/api/view/callback?recordid=fixture")
    }

    @MainActor
    func testUnsupportedPageDoesNotInstallReaderOrClaimOwnership() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://example.com/replay/fixture")!
        try await load(reader, url: url, body: "<div>不属于本次回放</div>")
        let packet = try await probe(reader, url: url)
        XCTAssertTrue(packet.isEmpty)
        let owner = try await reader.webView.evaluateJavaScript("typeof window.__studyReplayOwner") as? String
        XCTAssertEqual(owner, "undefined")
        for value in ["http://view.csslcloud.net/replay", "https://view.csslcloud.net.evil.example/replay",
                      "https://view.csslcloud.net:9443/replay", "https://PLACEHOLDER@view.csslcloud.net/replay"] {
            XCTAssertFalse(BrowserCourseSession.isReplayPage(URL(string: value)!))
        }
    }
}
