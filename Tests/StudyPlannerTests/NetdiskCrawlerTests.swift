import XCTest
import WebKit
import StudyCore
@testable import StudyPlanner

/// Answers provider calls from a scripted share, so the crawl path can be tested without a network.
private actor StubTransport: NetdiskTransport {
    /// Listings arrive as JSON text so the stub itself stays sendable across actors.
    private var pages: [String: [String]]
    private var calls: [(path: String, query: [String: String])] = []
    private var failing: Set<String> = []
    /// Largest page the stub will hand out, mirroring a provider that caps `_size`.
    private let maximumPageSize: Int
    private let declaredCounts: [String: Int]

    init(pages: [String: [String]], maximumPageSize: Int = 200,
         declaredCounts: [String: Int] = [:]) {
        self.pages = pages
        self.maximumPageSize = maximumPageSize
        self.declaredCounts = declaredCounts
    }
    func recorded() -> [(path: String, query: [String: String])] { calls }
    func fail(_ fid: String) { failing.insert(fid) }

    func get(path: String, query: [String: String]) async throws -> Data {
        calls.append((path, query))
        if path.hasSuffix("/sharepage/token") { return try Self.token() }
        let fid = query["pdir_fid"] ?? "0"
        if failing.contains(fid) {
            let body: [String: Any] = ["status": 500, "code": 50001, "message": "目录读取失败"]
            return try JSONSerialization.data(withJSONObject: body)
        }
        let page = Int(query["_page"] ?? "1") ?? 1
        let requested = Int(query["_size"] ?? "200") ?? 200
        let size = max(1, min(requested, maximumPageSize))
        let items = pages[fid] ?? []
        let slice = Array(items.dropFirst((page - 1) * size).prefix(size)).map { text -> Any in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [:]
        }
        // `_count` is the folder total, never the size of this page: that is what paging relies on.
        let body: [String: Any] = [
            "status": 200, "code": 0, "message": "ok",
            "data": ["list": slice, "is_owner": 0],
            "metadata": ["_page": page, "_size": size,
                         "_count": declaredCounts[fid] ?? items.count,
                         "_total": declaredCounts[fid] ?? items.count]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        calls.append((path, query))
        if path.hasSuffix("/sharepage/token") { return try Self.token() }
        let payload: [String: Any] = ["status": 404, "code": 41006, "message": "接口不存在"]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private static func token() throws -> Data {
        let body: [String: Any] = ["status": 200, "code": 0, "message": "ok",
                                   "data": ["stoken": "stub-stoken", "title": "01.【测试】高等数学强化班",
                                            "passcode": "0"]]
        return try JSONSerialization.data(withJSONObject: body)
    }
}

private actor CodeTransport: NetdiskTransport {
    private let code: Int
    private let message: String
    init(code: Int, message: String) { self.code = code; self.message = message }
    func get(path: String, query: [String: String]) async throws -> Data {
        let body: [String: Any] = ["status": 200, "code": 0, "message": "ok",
                                   "data": ["stoken": "s", "title": "t", "passcode": "0"]]
        return try JSONSerialization.data(withJSONObject: body)
    }
    func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        let payload: [String: Any] = ["status": 200, "code": code, "message": message]
        return try JSONSerialization.data(withJSONObject: payload)
    }
}

final class NetdiskCrawlerTests: XCTestCase {

    private func folder(_ fid: String, _ name: String, items: Int) -> String {
        Self.json(["fid": fid, "file_name": name, "dir": true, "file_type": 0, "category": 0,
                   "include_items": items, "share_fid_token": "token-\(fid)"])
    }
    private func video(_ fid: String, _ name: String, duration: Int, size: Int) -> String {
        Self.json(["fid": fid, "file_name": name, "dir": false, "file_type": 1, "category": 1,
                   "format_type": "video/mp4", "size": size, "duration": duration,
                   "video_width": 1920, "video_height": 1080, "status": 1, "risk_type": 0,
                   "share_fid_token": "token-\(fid)"])
    }
    private static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func crawl(_ transport: NetdiskTransport, link: String = "https://pan.quark.cn/s/48d8818e6cc0",
                       limits: NetdiskCrawler.Limits = .standard,
                       passcode: String? = nil) async throws -> NetdiskCrawler.Result {
        let crawler = NetdiskCrawler(transport: transport, limits: limits)
        let parsed = try XCTUnwrap(NetdiskLink.parse(link))
        return try await crawler.crawl(link: parsed, passcode: passcode, sourceURL: link,
                                       existingCourses: [], now: Date(timeIntervalSince1970: 1_790_497_416))
    }

    func testRecursiveCrawlBuildsCoursesFromNestedFolders() async throws {
        let transport = StubTransport(pages: [
            "0": [folder("c0ffee01", "02 课程【视频课在这里】", items: 1)],
            "c0ffee01": [folder("v1de0a01", "01 视频", items: 2)],
            "v1de0a01": [folder("57a9e001", "01.抢跑预备", items: 3), folder("57a9e002", "02.核心基础", items: 3)],
            "57a9e001": [video("a1", "第1讲 函数.mp4", duration: 600, size: 100_000_000),
                       video("a2", "第2讲 极限.mp4", duration: 900, size: 120_000_000),
                       video("a3", "第3讲 导数.mp4", duration: 1200, size: 140_000_000)],
            "57a9e002": [video("b1", "第1讲 连续.mp4", duration: 600, size: 100_000_000),
                       video("b2", "第2讲 积分.mp4", duration: 900, size: 120_000_000),
                       video("b3", "第3讲 微分方程.mp4", duration: 1200, size: 140_000_000)]
        ])
        let result = try await crawl(transport)

        XCTAssertEqual(result.scan.title, "01.【测试】高等数学强化班")
        XCTAssertEqual(result.scan.root.videoCount, 6)
        XCTAssertEqual(result.scan.packages.map(\.path).sorted(),
                       ["02 课程【视频课在这里】/01 视频/01.抢跑预备",
                        "02 课程【视频课在这里】/01 视频/02.核心基础"])
        XCTAssertEqual(result.courses.count, 2)
        XCTAssertTrue(result.courses.allSatisfy { $0.refusal == nil })
        XCTAssertEqual(result.courses.first?.snapshot.lessons.count, 3)
        XCTAssertEqual(result.scan.unreadFolders, 0)
        XCTAssertTrue(result.scan.issues.isEmpty)
    }

    func testPaginationIsFollowedCompletely() async throws {
        // Seven videos in one folder with a page size of three: three pages, no lesson lost.
        let items: [String] = (1...7).map {
            video("v\($0)", "第\($0)讲 高数.mp4", duration: 600, size: 100_000_000)
        }
        let transport = StubTransport(pages: ["0": [folder("c0ffee01", "高数强化", items: 7)],
                                              "c0ffee01": items], maximumPageSize: 3)
        let result = try await crawl(transport, limits: NetdiskCrawler.Limits(pageSize: 3))
        let package = try XCTUnwrap(result.scan.packages.first)
        XCTAssertEqual(package.videoCount, 7)
        XCTAssertEqual(package.videos.compactMap { NetdiskTitles.episode(in: $0.name) }, Array(1...7))
        let pageCalls = await transport.recorded().filter { $0.query["pdir_fid"] == "c0ffee01" }
        XCTAssertEqual(pageCalls.count, 3, "必须把 7 条记录分三页读全")
        XCTAssertEqual(pageCalls.map { $0.query["_page"] ?? "" }, ["1", "2", "3"])
    }

    func testPageLimitAppliesSeparatelyToEachFolder() async throws {
        let first = (1...5).map { video("a\($0)", "第\($0)讲 高数.mp4", duration: 600, size: 1_000) }
        let second = (1...5).map { video("b\($0)", "第\($0)讲 线代.mp4", duration: 600, size: 1_000) }
        let transport = StubTransport(pages: [
            "0": [folder("math", "高数课程", items: 5), folder("linear", "线代课程", items: 5)],
            "math": first, "linear": second
        ], maximumPageSize: 3)
        let result = try await crawl(transport,
                                     limits: NetdiskCrawler.Limits(maxPagesPerFolder: 2, pageSize: 3))
        XCTAssertEqual(result.scan.totalVideoCount, 10)
        XCTAssertEqual(result.scan.unreadFolders, 0)
    }

    func testPartialFolderIsReportedInsteadOfSilentlyAccepted() async throws {
        let items: [String] = (1...5).map {
            video("v\($0)", "第\($0)讲 高数.mp4", duration: 600, size: 100_000_000)
        }
        let transport = StubTransport(pages: ["0": [folder("c0ffee01", "高数强化", items: 99)],
                                              "c0ffee01": items], maximumPageSize: 3,
                                      declaredCounts: ["c0ffee01": 99])
        let result = try await crawl(transport, limits: NetdiskCrawler.Limits(pageSize: 3))
        XCTAssertGreaterThan(result.scan.unreadFolders, 0, "少读到的分页必须计入未读完")
    }

    func testDirectoryErrorsStopTheCrawlWithAReason() async throws {
        let transport = StubTransport(pages: ["0": [folder("c0ffee03", "高数强化", items: 2)],
                                              "c0ffee03": [video("v1", "第1讲.mp4", duration: 600, size: 1)]])
        await transport.fail("c0ffee03")
        do {
            _ = try await crawl(transport)
            XCTFail("目录读失败时必须报错，不能把半个课程当完整")
        } catch let error as NetdiskAPIError {
            XCTAssertEqual(error, .provider(code: 50001, message: "目录读取失败"))
        }
    }

    func testPasscodeProtectedShareAsksForTheCode() async throws {
        let transport = CodeTransport(code: 41008, message: "需要提取码")
        do {
            _ = try await crawl(transport)
            XCTFail("需要提取码时应提示")
        } catch let error as NetdiskAPIError {
            XCTAssertEqual(error, .needsPasscode)
        }
    }

    func testExpiredShareIsReportedAsGone() async throws {
        let transport = CodeTransport(code: 41006, message: "分享不存在")
        do {
            _ = try await crawl(transport)
            XCTFail("失效分享应报错")
        } catch let error as NetdiskAPIError {
            XCTAssertEqual(error, .shareGone("分享不存在"))
        }
    }

    func testFolderLimitStopsAndSaysSo() async throws {
        // A share with 12 flat folders, each holding one video, read with a 4 folder budget.
        let folderPages: [String: [String]] = Dictionary(uniqueKeysWithValues: (1...12).map { index in
            ("f\(index)", [video("v\(index)", "第\(index)讲.mp4", duration: 600, size: 1_000)])
        })
        let root: [String] = (1...12).map {
            folder("f\($0)", String(format: "%02d 阶段", $0), items: 1)
        }
        let transport = StubTransport(pages: folderPages.merging(["0": root]) { _, new in new })
        let result = try await crawl(transport, limits: NetdiskCrawler.Limits(maxFolders: 4))
        XCTAssertTrue(result.scan.issues.contains { $0.contains("读取上限") })
        XCTAssertGreaterThan(result.scan.unreadFolders, 0)
    }

    func testFileLimitRefusesAnOversizedShare() async throws {
        let items: [String] = (1...30).map {
            video("v\($0)", "第\($0)讲.mp4", duration: 600, size: 1_000)
        }
        let transport = StubTransport(pages: ["0": items])
        do {
            _ = try await crawl(transport, limits: NetdiskCrawler.Limits(maxFiles: 10))
            XCTFail("超过上限应明确拒绝")
        } catch let error as NetdiskCrawler.CrawlError {
            XCTAssertTrue(error.localizedDescription.contains("单次导入太大"))
        }
    }

    func testDuplicateCoursesAreReportedDuringCrawl() async throws {
        // Two folders holding the same four lessons, filed under different names.
        func course(_ prefix: String, _ fid: String, _ childFid: String) -> (root: String, pages: [String: [String]]) {
            let pages: [String: [String]] = [
                fid: [folder(childFid, "章节", items: 3),
                      video(prefix + "1", "第1讲 函数.mp4", duration: 600, size: 100_000_000),
                      video(prefix + "2", "第2讲 极限.mp4", duration: 600, size: 100_000_000),
                      video(prefix + "3", "第3讲 导数.mp4", duration: 600, size: 100_000_000)],
                childFid: [video(prefix + "4", "第4讲 连续.mp4", duration: 600, size: 100_000_000)]
            ]
            return (folder(fid, prefix == "a" ? "高数强化" : "高等数学强化", items: 4), pages)
        }
        let first = course("a", "aa11aa11", "ccc11111")
        let second = course("b", "bb22bb22", "ddd22222")
        var listings = first.pages
        for (key, value) in second.pages { listings[key] = value }
        listings["0"] = [first.root, second.root]
        let transport = StubTransport(pages: listings)
        let result = try await crawl(transport)
        XCTAssertEqual(result.scan.packages.count, 2)
        XCTAssertEqual(result.courses.count, 2)
        XCTAssertEqual(result.duplicates.droppedPackages.count, 1, "课节完全相同的两门课应识别为重复")
        XCTAssertEqual(NetdiskDedup.applied(result.scan.packages, report: result.duplicates).count, 1)
    }


    func testFragmentLinkStartsAtThatFolder() async throws {
        // The link points at a chapter folder that holds its own lessons plus one section folder.
        let transport = StubTransport(pages: [
            "0": [folder("dead0001", "02 课程", items: 1)],
            "dead0001": [video("v1", "第1讲.mp4", duration: 600, size: 1_000)],
            "c0ffee02": [folder("57a9e001", "第1章 极限", items: 3),
                         folder("57a9e002", "第2章 导数", items: 1),
                         folder("57a9e003", "第3章 积分", items: 1),
                         video("d1", "第1节 定义.mp4", duration: 600, size: 1_000),
                         video("d2", "第2节 性质.mp4", duration: 600, size: 1_000),
                         video("d3", "第3节 例题.mp4", duration: 600, size: 1_000)],
            "57a9e001": [video("e1", "第4节 综合.mp4", duration: 600, size: 1_000)],
            "57a9e002": [video("e2", "第5节 求导.mp4", duration: 600, size: 1_000)],
            "57a9e003": [video("e3", "第6节 积分.mp4", duration: 600, size: 1_000)]
        ])
        let result = try await crawl(transport, link: "https://pan.quark.cn/s/48d8818e6cc0#/list/share/c0ffee02")
        // The linked chapter is one course: its own three lessons plus the one in its section folder.
        XCTAssertEqual(result.scan.packages.map(\.path), [""])
        XCTAssertEqual(result.scan.packages.first?.videoCount, 6)
        XCTAssertEqual(result.scan.packages.first?.name, "01.【测试】高等数学强化班")
        XCTAssertTrue(result.scan.issues.contains { $0.contains("子目录") })
        let listed = Set(await transport.recorded().map { $0.query["pdir_fid"] ?? "" })
        XCTAssertFalse(listed.contains("0"), "给了子目录就不该再列根目录：\(listed)")
    }

    func testProviderEntryMapping() {
        let item = QuarkShareAPI.Item(fid: "f", shareFidToken: "t", fileName: "第1讲.mp4", dir: false,
                                      fileType: 1, category: 1, formatType: "video/mp4", size: 123,
                                      duration: 6693, videoWidth: 1280, videoHeight: 720,
                                      updatedAt: 1_789_695_424_797, includeItems: nil, riskType: 0,
                                      ban: false, badContent: false, status: 1)
        let entry = NetdiskCrawler.entry(item, parentPath: "课程/第1章")
        XCTAssertEqual(entry.relativePath, "课程/第1章/第1讲.mp4")
        XCTAssertEqual(entry.durationSeconds, 6693)
        XCTAssertEqual(entry.width, 1280)
        XCTAssertTrue(NetdiskDigest.isVideo(entry))
        XCTAssertEqual(entry.updatedAt?.timeIntervalSince1970 ?? 0, 1_789_695_424.797, accuracy: 0.01)
    }
}

/// Drives the real injected script inside WebKit, the same way the app runs it.
final class QuarkCrawlerScriptTests: XCTestCase {
    @MainActor
    private func ready(_ webView: WKWebView) async throws {
        webView.loadHTMLString("<html><body>夸克抓取器测试</body></html>",
                               baseURL: URL(string: "https://pan.quark.cn/s/48d8818e6cc0")!)
        for _ in 0..<60 {
            if (try? await webView.evaluateJavaScript("typeof window.studyQuarkCrawler")) as? String == "object" {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("抓取脚本没有注入")
    }

    @MainActor
    private func webView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebViewNetdiskTransport.script, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true))
        return WKWebView(frame: .zero, configuration: configuration)
    }

    @MainActor
    func testScriptRefusesToCallAnythingButTheNetdiskAPI() async throws {
        let view = webView()
        try await ready(view)
        let result = try await view.callAsyncJavaScript(
            "return JSON.stringify(await window.studyQuarkCrawler.get('https://example.com/steal', {}));",
            arguments: [:], in: nil, contentWorld: .page) as? String
        let payload = try XCTUnwrap(result?.data(using: .utf8))
        let envelope = try JSONDecoder().decode(WebViewNetdiskTransport.Envelope.self, from: payload)
        XCTAssertFalse(envelope.ok)
        XCTAssertTrue(envelope.error?.contains("拒绝访问非网盘接口") == true)
    }

    @MainActor
    func testScriptBuildsTheSameQueryTheAPIExpects() async throws {
        let view = webView()
        try await ready(view)
        let result = try await view.callAsyncJavaScript(
            """
            const captured = [];
            window.fetch = async (url, init) => {
              captured.push(String(url) + '|' + ((init && init.method) || 'GET'));
              return new Response(JSON.stringify({status: 200, code: 0, data: {}}),
                                  {status: 200, headers: {'content-type': 'application/json'}});
            };
            const answer = await window.studyQuarkCrawler.get('/1/clouddrive/share/sharepage/detail',
                                                              {pwd_id: 'abc123', stoken: 's t', _page: 2});
            return JSON.stringify({captured: captured, answer: answer});
            """,
            arguments: [:], in: nil, contentWorld: .page) as? String
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let captured = try XCTUnwrap(decoded["captured"] as? [String])
        let url = try XCTUnwrap(captured.first)
        XCTAssertTrue(url.hasPrefix("/1/clouddrive/share/sharepage/detail?"), url)
        XCTAssertTrue(url.contains("pwd_id=abc123"), url)
        XCTAssertTrue(url.contains("stoken=s%20t"), "参数必须转义：\(url)")
        XCTAssertTrue(url.contains("_page=2"), url)
        XCTAssertTrue(url.contains("pr=ucpro"), "必须带上网页端的公共参数：\(url)")
        XCTAssertTrue(url.hasSuffix("|GET"), url)
        let answer = try XCTUnwrap(decoded["answer"] as? [String: Any])
        XCTAssertEqual(answer["ok"] as? Bool, true)
        XCTAssertEqual(answer["status"] as? Int, 200)
    }

    @MainActor
    func testScriptPostsJSONBodies() async throws {
        let view = webView()
        try await ready(view)
        let result = try await view.callAsyncJavaScript(
            """
            let seen = null;
            window.fetch = async (url, init) => {
              seen = {method: init.method, body: init.body, type: init.headers['Content-Type']};
              return new Response('{"status":200,"code":0}', {status: 200});
            };
            await window.studyQuarkCrawler.post('/1/clouddrive/share/sharepage/token', {},
                                                {pwd_id: 'abc123', passcode: '', support_visit_limit_private_share: true});
            return JSON.stringify(seen);
            """,
            arguments: [:], in: nil, contentWorld: .page) as? String
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["method"] as? String, "POST")
        XCTAssertEqual(decoded["type"] as? String, "application/json")
        let body = try XCTUnwrap((decoded["body"] as? String)?.data(using: .utf8))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["pwd_id"] as? String, "abc123")
        XCTAssertEqual(json["support_visit_limit_private_share"] as? Bool, true)
    }

    @MainActor
    func testPageEnvelopeErrorsBecomeReadableErrors() throws {
        let failing = Data(#"{"ok":false,"error":"页面请求失败：TypeError"}"#.utf8)
        XCTAssertThrowsError(try WebViewNetdiskTransport.payload(fromPage: failing)) { error in
            XCTAssertEqual((error as? NetdiskAPIError)?.errorDescription, "页面请求失败：TypeError")
        }
        let http = Data(#"{"ok":true,"status":503,"text":""}"#.utf8)
        XCTAssertThrowsError(try WebViewNetdiskTransport.payload(fromPage: http)) { error in
            XCTAssertEqual(error as? NetdiskAPIError, .http(503, ""))
        }
        let good = Data(#"{"ok":true,"status":200,"text":"{\"code\":0}"}"#.utf8)
        XCTAssertEqual(try WebViewNetdiskTransport.payload(fromPage: good), Data(#"{"code":0}"#.utf8))
    }
}
