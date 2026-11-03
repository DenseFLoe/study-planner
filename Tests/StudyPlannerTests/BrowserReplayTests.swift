import XCTest
import WebKit
@testable import StudyPlanner

final class BrowserReplayTests: XCTestCase {
    @MainActor
    private func load(_ reader: WebLessonReader, url: URL, body: String) async throws {
        let documentID = UUID().uuidString
        reader.webView.loadHTMLString("""
        <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"></head>
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
    func testExplicitPendingTextOverridesScheduledTimesAndWorksOnWrapper() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        for path in ["https://view.csslcloud.net/replay/fixture", "https://ixuecheng.cn/backWindow"] {
            let url = URL(string: path)!
            for label in ["课程尚未更新", "回放生成中，请耐心等待", "暂无直播回放", "直播尚未开始",
                          "直播时间：2099-11-03 19:00-20:00", "直播时间：2099-11-3 7:00"] {
                try await load(reader, url: url, body: "<div>待发布课节</div><div>直播时间：2026-07-29 14:00-15:00</div><div>\(label)</div>")
                let packet = try await probe(reader, url: url)
                let metadata = try XCTUnwrap(packet["metadata"] as? [String: Any])
                XCTAssertEqual(metadata["availability"] as? String, "pending", label)
                XCTAssertTrue(metadata["durationSeconds"] is NSNull)
                let decoded = try JSONDecoder().decode(XuechengReplayMetadata.self, from: JSONSerialization.data(withJSONObject: metadata))
                let row = XuechengCatalog.Row(name: "待发布课节", replay: true, previouslyWatched: false, key: "0")
                let lesson = WebLessonReader.xuechengLesson(id: "fixture:0", row: row, metadata: decoded)
                XCTAssertFalse(lesson.published)
                XCTAssertFalse(lesson.requiresDuration)
                XCTAssertEqual(lesson.id, "fixture:0")
            }
        }
    }

    @MainActor
    func testPendingWithoutTitleAndAsynchronousStatusAreRecognized() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://view.csslcloud.net/replay/fixture")!
        try await load(reader, url: url, body: "")
        _ = try await probe(reader, url: url)
        _ = try await reader.webView.evaluateJavaScript("document.body.innerHTML = '<div>回放生成中</div>'; true;")
        let packet = try await probe(reader, url: url)
        let metadata = try XCTUnwrap(packet["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["availability"] as? String, "pending")
        XCTAssertEqual(metadata["title"] as? String, "")
    }

    @MainActor
    func testFailuresHiddenMessagesAndDiscussionDoNotBecomePending() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://view.csslcloud.net/replay/fixture")!
        for failure in ["请先登录", "验证码", "网络异常", "没有权限", "视频不存在"] {
            try await load(reader, url: url, body: "<div>课节</div><div>尚未更新</div><div>\(failure)</div>")
            let packet = try await probe(reader, url: url)
            XCTAssertEqual((packet["metadata"] as? [String: Any])?["availability"] as? String, "blocked")
        }
        try await load(reader, url: url, body: "<div>课节</div><div>尚未更新</div><div>登录成功</div>")
        let signedIn = try await probe(reader, url: url)
        XCTAssertEqual((signedIn["metadata"] as? [String: Any])?["availability"] as? String, "pending")
        for body in ["<div>正在加载</div>", "<div style='display:none'>尚未更新</div>",
                     "<div class='chat'><span>尚未更新</span></div>", "<div>尚未更新的课程识别方法</div>"] {
            try await load(reader, url: url, body: body)
            let packet = try await probe(reader, url: url)
            XCTAssertTrue(packet["metadata"] is NSNull, body)
        }
    }

    @MainActor
    func testActualPlayerDurationWinsOverStalePendingNotice() async throws {
        let reader = WebLessonReader(useExternalBrowser: false); defer { reader.stop() }
        let url = URL(string: "https://view.csslcloud.net/replay/fixture")!
        try await load(reader, url: url, body: "<div>课节</div><div>回放生成中</div><video></video>")
        _ = try await reader.webView.evaluateJavaScript("Object.defineProperty(document.querySelector('video'), 'duration', {value:120}); true;")
        let packet = try await probe(reader, url: url)
        let metadata = try XCTUnwrap(packet["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["durationSeconds"] as? Int, 120)
        XCTAssertNil(metadata["availability"])
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
