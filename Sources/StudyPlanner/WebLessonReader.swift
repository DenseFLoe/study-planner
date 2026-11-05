import SwiftUI
import AppKit
import Combine
import WebKit
import StudyCore

struct WebCourseAccount: Decodable {
    struct Unavailable: Decodable { let name: String; let reason: String }
    let snapshots: [WebCourseSnapshot]
    let unavailable: [Unavailable]
    let issues: [String]
    let packageCount: Int
}

/// One JSON response the page loaded on its own, recorded by the injected sniffer.
private struct SniffedResponse: Decodable {
    let url: String
    let body: String
}

private struct SniffedPage: Decodable {
    let title: String
    let payloads: [SniffedResponse]
    let revision: Int
}

struct XuechengCatalog: Decodable {
    struct Row: Decodable {
        let name: String
        let replay: Bool
        let previouslyWatched: Bool
        let key: String?
        var availability: String? = nil
    }
    let courseID: String
    let name: String
    let rows: [Row]
}

struct XuechengReplayMetadata: Decodable {
    let title: String
    let durationSeconds: Double?
    let watchedPercent: Double?
    var availability: String? = nil

    func matches(_ name: String) -> Bool {
        title.filter { !$0.isWhitespace } == name.filter { !$0.isWhitespace }
    }
    var hasDuration: Bool {
        guard let seconds = durationSeconds else { return false }
        return seconds.isFinite && seconds > 0 && seconds <= 36000 && availability == nil
    }
}

private struct XuechengReplayTarget {
    var url: URL? = nil
    var availability: String? = nil
}

@MainActor @Observable
final class WebLessonReader: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    /// Built-in entry point; the editable address bar can point the same reader at any other HTTPS page.
    static let defaultAddress = "https://www.kaoyanvip.cn/appmanage/my/mycourse"
    static let defaultURL = URL(string: WebLessonReader.defaultAddress)!
    var result: WebCourseAccount?
    var status = "在默认浏览器登录并进入课程页面后，点击“读取浏览器当前课程”。" {
        didSet { updateProgress?(status) }
    }
    private var updateProgress: ((String) -> Void)?
    private var readFailure: Error?
    var busy = false
    var lastRefresh: Date?
    var webView: WKWebView!
    private let browser: BrowserCourseSession?
    private var browserConnected = false
    private var browserTicking = false
    private var browserApplication: SupervisedApplication?
    private var browserCleanup: Task<Void, Never>?
    var browserName = "默认浏览器"
    /// Address bar text; `targetURL` is the address the reader currently reads.
    var address = WebLessonReader.defaultAddress
    private(set) var targetURL = WebLessonReader.defaultURL
    private var generation = UUID()
    private var stopped = false
    private var opened = false
    private var attemptedURL: String?
    private var redirectAttempts = 0
    private var replayURLContinuation: CheckedContinuation<XuechengReplayTarget, Never>?
    private var replayURLRequestID: UUID?
    private var replayMetadataContinuation: CheckedContinuation<XuechengReplayMetadata?, Never>?
    private var replayMetadataRequestID: UUID?
    private var replayWebView: WKWebView?
    private var replayCache: [String: XuechengReplayMetadata] = [:]
    private var replayAttempts = Set<String>()
    private static func isXuechengHost(_ host: String?) -> Bool {
        let value = host?.lowercased()
        return value == "ixuecheng.cn" || value == "www.ixuecheng.cn"
    }
    /// Sites without a dedicated adapter are read from the JSON the page itself loaded.
    var isGenericSite: Bool { !["kaoyanvip.cn", "www.kaoyanvip.cn"].contains(targetURL.host?.lowercased() ?? "") }
    var isXuechengSite: Bool { Self.isXuechengHost(targetURL.host) }
    private(set) var capturedResponses = 0
    private var capturedRevision = -1
    static var script: String { resource("CourseCrawler") }
    /// External browsers install this on explicit connection; test WebViews inject at document start.
    static var genericScript: String { resource("GenericCrawler") }
    static var xuechengScript: String { resource("XuechengAvailability") + "\n" + resource("XuechengCrawler") }
    static var replayScript: String { resource("XuechengAvailability") + "\n" + resource("XuechengReplay") }
    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }
    init(useExternalBrowser: Bool = true) {
        browser = useExternalBrowser ? BrowserCourseSession() : nil
        super.init()
        if useExternalBrowser { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(self, name: "courseStatus")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.genericScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(source: Self.xuechengScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }
    /// One complete read for a saved binding. No other packages are imported or updated.
    func managedSnapshot(url: URL, packageID: String, interactive: Bool,
                         progress: ((String) -> Void)? = nil) async throws -> WebCourseSnapshot {
        updateProgress = progress
        defer { updateProgress = nil }
        guard let browser, let site = CourseWebsite.identify(url),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
            throw WebsiteUpdateError.message("无法找到受支持的默认浏览器。")
        }
        let app = SupervisedApplication(bundleID: bundleID, name: appURL.deletingPathExtension().lastPathComponent, path: appURL.path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let running: NSRunningApplication
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { running = existing }
        else { running = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) }
        do {
            let page = try await browser.openManaged(application: app, pid: running.processIdentifier, target: url,
                credentials: { try WebsiteCredentialVault.load(site, interactive: interactive) }, allowPermissionPrompt: interactive)
            targetURL = page
            try await browser.install(Self.genericScript + "\n" + Self.script + "\n" + Self.xuechengScript)
            let snapshot: WebCourseSnapshot
            if site == .yantu {
                let body = "return await window.studyCourseCrawler.crawl(\(BrowserCourseSession.literal(packageID)));"
                let data = try await browser.evaluate(body)
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
                snapshot = try decoder.decode(WebCourseSnapshot.self, from: data)
            } else {
                busy = true
                await readGeneric(generation: generation, page: page, forceCatalog: true, failOnReplayFailure: true)
                if let readFailure { throw readFailure }
                guard let result, result.issues.isEmpty,
                      let found = result.snapshots.first(where: { $0.packageID == packageID && WebCourseIdentity.origin($0.sourceURL) == WebCourseIdentity.origin(url.absoluteString) }) else {
                    throw WebsiteUpdateError.message("未取得完整的学丞课程，请在更新窗口检查登录和课程目录后重试。")
                }
                snapshot = found
            }
            guard snapshot.packageID == packageID, snapshot.importProblem == nil,
                  WebCourseIdentity.origin(snapshot.sourceURL) == WebCourseIdentity.origin(url.absoluteString) else {
                throw WebsiteUpdateError.message("网站返回的课程不匹配或课节不完整，保留原课程，请检查后重试。")
            }
            await browser.stop()
            return snapshot
        } catch {
            // Keep the dedicated page available for a captcha or manual login; never loop login attempts.
            await browser.stop(closeManaged: error is CancellationError || Task.isCancelled)
            throw error
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "replayMetadata" {
            guard message.webView === replayWebView,
                  (message.frameInfo.securityOrigin.host == "view.csslcloud.net" ||
                    (Self.isXuechengHost(message.frameInfo.securityOrigin.host) && message.frameInfo.request.url?.path == "/backWindow")),
                  let body = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let metadata = try? JSONDecoder().decode(XuechengReplayMetadata.self, from: data),
                  metadata.hasDuration || metadata.availability == "pending" || metadata.availability == "blocked" else { return }
            finishReplayMetadata(metadata)
            return
        }
        guard busy, message.frameInfo.isMainFrame, let host = webView.url?.host,
              message.frameInfo.securityOrigin.host.caseInsensitiveCompare(host) == .orderedSame,
              let text = message.body as? String else { return }
        status = String(text.prefix(300))
    }
    func open() { opened = true; load(targetURL) }
    /// Points the same reader and the same crawler at whatever the address bar says.
    func loadAddress() {
        guard !stopped else { return }
        guard let url = WebLessonTiming.addressURL(address) else {
            status = "请输入有效的 HTTPS 网址，例如 www.kaoyanvip.cn。"
            return
        }
        address = url.absoluteString
        targetURL = url
        finishReplayURL(nil)
        finishReplayMetadata(nil)
        replayCache.removeAll()
        replayAttempts.removeAll()
        busy = false
        result = nil
        status = "正在打开 \(url.host ?? url.absoluteString)…"
        load(url)
    }
    func useDefaultAddress() {
        address = Self.defaultAddress
        loadAddress()
    }
    private func load(_ url: URL) {
        attemptedURL = nil
        redirectAttempts = 0
        if let browser {
            generation = UUID(); browserConnected = false; busy = false
            browserCleanup = Task { await browser.stop() }
            guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
                  let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
                status = "没有找到可打开此网址的默认浏览器。"; return
            }
            browserApplication = SupervisedApplication(bundleID: bundleID, name: appURL.deletingPathExtension().lastPathComponent, path: appURL.path)
            browserName = browserApplication!.name
            if NSWorkspace.shared.open(url) {
                status = "已在\(browserName)打开网站。登录并选中课程标签页后，回到这里点击“读取浏览器当前课程”。"
            } else { status = "未能打开默认浏览器，请检查系统默认浏览器设置后重试。" }
            return
        }
        webView.load(URLRequest(url: url))
    }
    func stop() {
        stopped = true; generation = UUID(); busy = false
        finishReplayURL(nil)
        finishReplayMetadata(nil)
        if let browser { browserConnected = false; Task { await browser.stop() }; return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "courseStatus")
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
    }
    func refresh(forceCatalog: Bool = true) {
        if browser != nil { refreshBrowser(forceCatalog: forceCatalog, reconnect: true); return }
        guard !busy, !stopped, let page = webView.url,
              WebLessonTiming.isSameWebsite(current: page, target: targetURL) else {
            if !busy { status = "请先登录并进入“我的课程”，登录成功后会自动抓取。" }
            return
        }
        busy = true; generation = UUID()
        if forceCatalog { replayAttempts.removeAll(); replayCache = replayCache.filter { $0.value.hasDuration } }
        let current = generation
        if isGenericSite {
            status = "正在识别网页已加载的课程数据…"
            Task { @MainActor in await readGeneric(generation: current, page: page, forceCatalog: forceCatalog) }
        } else {
            result = nil
            status = "正在读取网页课程接口…"
            Task { @MainActor in await readAdapted(generation: current) }
        }
    }
    private func evaluate(_ body: String, arguments: [String: Any]) async throws -> Any? {
        if let browser {
            let argumentsJSON = String(data: try JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
            let data = try await browser.evaluate(body, argumentsJSON: argumentsJSON)
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }
        return try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func refreshBrowser(forceCatalog: Bool, reconnect: Bool) {
        guard let browser, !stopped, !busy else { return }
        busy = true; generation = UUID()
        let current = generation
        Task { @MainActor in
            do {
                let page: URL
                if reconnect {
                    await browserCleanup?.value
                    guard !stopped, generation == current else { return }
                    guard let app = browserApplication,
                          let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
                        throw BrowserCourseError.message("请先点击“在默认浏览器打开”。")
                    }
                    page = try await browser.connect(application: app, pid: running.processIdentifier, target: targetURL)
                    try await browser.install(Self.genericScript + "\n" + Self.script + "\n" + Self.xuechengScript)
                    browserConnected = true
                } else { page = try await browser.currentPage() }
                guard !stopped, generation == current else { return }
                if forceCatalog { replayAttempts.removeAll(); replayCache = replayCache.filter { $0.value.hasDuration } }
                status = "正在读取\(browserName)中的课程数据…"
                if isGenericSite { await readGeneric(generation: current, page: page, forceCatalog: forceCatalog) }
                else { result = nil; await readAdapted(generation: current) }
            } catch {
                guard !stopped, generation == current else { return }
                browserConnected = false; busy = false
                status = error.localizedDescription
            }
        }
    }

    private func tickBrowser(autoRefresh: Bool) {
        guard let browser, browserConnected, !stopped, !busy, !browserTicking else { return }
        browserTicking = true
        let current = generation
        Task { @MainActor in
            defer { browserTicking = false }
            do {
                _ = try await browser.currentPage()
                guard !stopped, current == generation, !busy else { return }
                if autoRefresh, let lastRefresh, Date().timeIntervalSince(lastRefresh) >= 300 {
                    refreshBrowser(forceCatalog: true, reconnect: false)
                } else if isGenericSite {
                    let value = try await evaluate("return String(window.studyGenericCrawler?.revision() ?? -1);", arguments: [:])
                    guard !stopped, current == generation, !busy, let text = value as? String,
                          let revision = Int(text), revision > 0, revision != capturedRevision else { return }
                    refreshBrowser(forceCatalog: false, reconnect: false)
                }
            } catch {
                guard !stopped, current == generation else { return }
                browserConnected = false; status = error.localizedDescription
            }
        }
    }

    private func browserReplayMetadata(_ browser: BrowserCourseSession, url: URL) async throws -> XuechengReplayMetadata? {
        guard let data = try await browser.readReplay(url: url, script: Self.replayScript) else { return nil }
        return try? JSONDecoder().decode(XuechengReplayMetadata.self, from: data)
    }

    private func readAdapted(generation current: UUID) async {
        do {
            let value = try await evaluate("return JSON.stringify(await window.studyCourseCrawler.crawl(null));", arguments: [:])
            guard !stopped, generation == current else { return }
            guard let json = value as? String, let data = json.data(using: .utf8) else { throw CocoaError(.coderReadCorrupt) }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            result = try decoder.decode(WebCourseAccount.self, from: data)
            lastRefresh = Date()
            status = "已抓取 \(result?.snapshots.count ?? 0) 个课程包；请核对汇总后生成计划。"
        } catch {
            guard !stopped, generation == current else { return }
            status = "抓取失败：\(error.localizedDescription)。请确认已登录，或重新抓取。"
        }
        busy = false
    }
    /// Sites without an adapter are read from their own already-loaded JSON; nothing new is requested.
    private func readGeneric(generation current: UUID, page: URL, forceCatalog: Bool,
                             failOnReplayFailure: Bool = false) async {
        readFailure = nil
        do {
            var catalog: XuechengCatalog?
            if Self.isXuechengHost(page.host), page.path == "/detail" {
                status = "正在按顺序读取各层课程目录，请等待自动读取完成…"
            }
            if Self.isXuechengHost(page.host), page.path == "/detail",
               let value = try await evaluate("return JSON.stringify(await window.studyXuechengCrawler?.catalog(force));", arguments: ["force": forceCatalog]) as? String,
               let data = value.data(using: .utf8) {
                catalog = try? JSONDecoder().decode(XuechengCatalog.self, from: data)
            }
            guard !stopped, generation == current else { return }
            guard let value = try await evaluate("return JSON.stringify({title: document.title || '', payloads: window.studyGenericCrawler ? window.studyGenericCrawler.snapshot() : [], revision: window.studyGenericCrawler?.revision() ?? -1});", arguments: [:]) as? String,
                  let data = value.data(using: .utf8) else { throw CocoaError(.coderReadCorrupt) }
            let sniffed = try JSONDecoder().decode(SniffedPage.self, from: data)
            let payloads = sniffed.payloads
            guard !stopped, generation == current else { return }
            // Include responses produced by our own directory traversal in the consumed revision.
            capturedRevision = sniffed.revision
            let address = page.absoluteString
            let title = sniffed.title
            var snapshots = await Task.detached(priority: .userInitiated) {
                GenericCourseDigest.snapshots(from: payloads.map { CapturedResponse(url: $0.url, body: $0.body) },
                                              pageURL: address, pageTitle: title, now: Date())
            }.value
            guard !stopped, generation == current else { return }
            capturedResponses = payloads.count
            if let catalog, !catalog.rows.isEmpty {
                let course = try await collectXuecheng(catalog, page: page, baseSnapshots: snapshots, generation: current,
                                                      failOnReplayFailure: failOnReplayFailure)
                guard !stopped, generation == current else { return }
                snapshots = Self.merged(snapshots, with: [course])
            }
            if snapshots.isEmpty {
                if let existing = result, !existing.snapshots.isEmpty {
                    status = "本轮没有识别到新的课程数据；已识别的 \(existing.snapshots.count) 门课程仍保留在下方。"
                } else if let catalog {
                    status = "「\(catalog.name)」目录暂无可读取课节；可继续打开其他课程。"
                    lastRefresh = Date()
                } else {
                    status = "已捕获 \(payloads.count) 个数据接口，但没有识别到课程结构。请在该网站里打开「我的课程」或课程详情页，等课节列表出现后再读取。若页面数据已在连接前加载，请在浏览器内返回列表后重新点开课程。"
                }
            } else {
                // Courses read from earlier pages are kept: a site usually needs one visit per course.
                let merged = Self.merged(result?.snapshots ?? [], with: snapshots)
                result = WebCourseAccount(snapshots: merged, unavailable: [], issues: [], packageCount: merged.count)
                lastRefresh = Date()
                if let catalog, !catalog.rows.isEmpty {
                    let course = merged.first { $0.packageID == "generic:" + catalog.courseID && WebCourseIdentity.origin($0.sourceURL) == WebCourseIdentity.origin(address) }
                    let missing = course?.unknownDurations ?? 0
                    let pending = course?.lessons.filter { !$0.published }.count ?? 0
                    status = missing == 0
                        ? "已读取 \(catalog.rows.count) 个直播条目，其中 \(pending) 个尚未更新，保留目录并等待后续发布；网站未提供的观看进度按 0% 计。请核对后生成计划。"
                        : "已读取 \(catalog.rows.count) 个直播条目，其中 \(missing) 个回放未取得时长；请重新抓取。"
                } else {
                    status = "本轮识别出 \(snapshots.count) 门课程，累计 \(merged.count) 门；继续打开其他课程会自动累加，核对后生成计划。"
                }
            }
        } catch {
            guard !stopped, generation == current else { return }
            readFailure = error
            status = "识别失败：\(Self.crawlerFailureDescription(error))。"
        }
        busy = false
    }
    static func crawlerFailureDescription(_ error: Error) -> String {
        let exception = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
        let reasons = ["课程目录加载超时，请重新识别课程", "课程目录请求失败，请重新识别课程",
                       "课程目录结构已变化", "课程页面已切换，请重新读取"]
        return reasons.first { exception.contains($0) } ?? error.localizedDescription
    }
    /// Keeps the fuller reading of a course, so revisiting a page never shrinks what was already found.
    static func merged(_ existing: [WebCourseSnapshot], with fresh: [WebCourseSnapshot]) -> [WebCourseSnapshot] {
        var byID: [String: WebCourseSnapshot] = [:]
        var order: [String] = []
        for snapshot in existing {
            if byID.updateValue(snapshot, forKey: snapshot.identityKey) == nil { order.append(snapshot.identityKey) }
        }
        for snapshot in fresh {
            if var previous = byID[snapshot.identityKey] {
                var positions = Dictionary(uniqueKeysWithValues: previous.lessons.enumerated().map { ($0.element.id, $0.offset) })
                var matched: Set<Int> = []
                for lesson in snapshot.lessons {
                    let position = positions[lesson.id] ?? previous.lessons.indices.first {
                        !matched.contains($0) && previous.lessons[$0].name == lesson.name &&
                        (previous.lessons[$0].kind == "living" || lesson.kind == "living")
                    }
                    if let position {
                        matched.insert(position)
                        let old = previous.lessons[position]
                        var better = lesson
                        if better.durationSeconds == nil, old.durationSeconds != nil {
                            better.durationSeconds = old.durationSeconds
                            if better.kind == "unknown" {
                                better.kind = old.kind; better.requiresDuration = old.requiresDuration
                                better.published = old.published
                            }
                        }
                        if better.watchedPercent == nil || (better.watchedPercent == 0 && (old.watchedPercent ?? 0) > 0) {
                            better.watchedPercent = old.watchedPercent
                        }
                        better.markedFinished = better.markedFinished || old.markedFinished
                        previous.lessons[position] = better
                        positions[better.id] = position
                    } else {
                        positions[lesson.id] = previous.lessons.count
                        previous.lessons.append(lesson)
                    }
                }
                if snapshot.name != "详情 - 学丞教育" { previous.name = snapshot.name }
                if snapshot.packageID.hasPrefix("generic:") {
                    previous.issues = Array(Set(previous.issues + snapshot.issues)).sorted()
                }
                if snapshot.sourceURL.contains("ixuecheng.cn/detail?") { previous.sourceURL = snapshot.sourceURL }
                if snapshot.sourceURL.contains("ixuecheng.cn/detail?") {
                    previous.expectedOutlines = snapshot.expectedOutlines
                    previous.fetchedOutlines = snapshot.fetchedOutlines
                    previous.issues = snapshot.issues
                }
                previous.fetchedAt = snapshot.fetchedAt
                byID[snapshot.identityKey] = previous
            } else {
                byID[snapshot.identityKey] = snapshot
                order.append(snapshot.identityKey)
            }
        }
        return order.compactMap { byID[$0] }
    }

    private func xuechengSnapshot(_ catalog: XuechengCatalog, page: URL,
                                  lessons: [WebCourseLesson], complete: Bool) -> WebCourseSnapshot {
        var source = URLComponents(url: page, resolvingAgainstBaseURL: false)
        let safeQueryItems = source?.queryItems?.filter { $0.name == "id" || $0.name == "type" }
        source?.queryItems = safeQueryItems
        return WebCourseSnapshot(packageID: "generic:" + catalog.courseID, name: catalog.name,
                                 sourceURL: source?.url?.absoluteString ?? "https://ixuecheng.cn/detail?id=" + catalog.courseID,
                                 fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: complete ? 1 : 0,
                                 lessons: lessons, issues: [])
    }
    private func collectXuecheng(_ catalog: XuechengCatalog, page: URL,
                                  baseSnapshots: [WebCourseSnapshot], generation current: UUID,
                                  failOnReplayFailure: Bool) async throws -> WebCourseSnapshot {
        let packageID = "generic:" + catalog.courseID
        var counts: [String: Int] = [:]
        var lessons: [WebCourseLesson] = []
        var resolved = 0
        var unresolved = 0
        for (index, row) in catalog.rows.enumerated() {
            let occurrence = (counts[row.name] ?? 0) + 1
            counts[row.name] = occurrence
            let id = packageID + ":live:" + row.name + ":" + (row.key ?? String(occurrence))
            var metadata = replayCache[id]
            if row.replay && row.availability == nil && metadata == nil && !replayAttempts.contains(id) && !stopped && generation == current {
                replayAttempts.insert(id)
                status = "正在进入直播回放 \(index + 1)/\(catalog.rows.count)：\(row.name)"
                let target = await replayURL(for: index)
                if let availability = target.availability {
                    metadata = XuechengReplayMetadata(title: row.name, durationSeconds: nil, watchedPercent: nil, availability: availability)
                    replayCache[id] = metadata
                } else if let url = target.url, !stopped, generation == current {
                    let candidate: XuechengReplayMetadata?
                    do { candidate = try await readReplayMetadata(at: url) }
                    catch {
                        if failOnReplayFailure || error is CancellationError || Task.isCancelled { throw error }
                        candidate = nil
                    }
                    if let candidate,
                       (candidate.hasDuration && candidate.matches(row.name)) ||
                        (candidate.availability == "pending" && (candidate.title.isEmpty || candidate.matches(row.name))) {
                        metadata = candidate
                        replayCache[id] = candidate
                    }
                }
            }
            try Task.checkCancellation()
            let lesson = Self.xuechengLesson(id: id, row: row, metadata: metadata)
            if failOnReplayFailure, lesson.published, lesson.durationSeconds == nil {
                throw WebsiteUpdateError.message("第 \(index + 1)/\(catalog.rows.count) 个直播回放未取得匹配的有效时长，更新已暂停，原课程已保留。请在浏览器检查回放后再点“立即更新”。")
            }
            lessons.append(lesson)
            guard !stopped, generation == current else { break }
            if lesson.published {
                if lesson.durationSeconds != nil { resolved += 1 } else { unresolved += 1 }
            }
            let partial = xuechengSnapshot(catalog, page: page, lessons: lessons, complete: false)
            let merged = Self.merged(result?.snapshots ?? [], with: Self.merged(baseSnapshots, with: [partial]))
            result = WebCourseAccount(snapshots: merged, unavailable: [],
                                      issues: ["学丞直播回放时长仍在读取，请等待完成。"], packageCount: merged.count)
            status = "已处理直播条目 \(index + 1)/\(catalog.rows.count)；取得时长 \(resolved) 个，尚未更新 \(lessons.filter { !$0.published }.count) 个，读取异常 \(unresolved) 个。"
        }
        return xuechengSnapshot(catalog, page: page, lessons: lessons,
                                complete: !stopped && generation == current && lessons.count == catalog.rows.count)
    }

    static func xuechengLesson(id: String, row: XuechengCatalog.Row, metadata: XuechengReplayMetadata?) -> WebCourseLesson {
        let pending = row.availability == "pending" || (row.availability != "blocked" &&
            metadata?.availability == "pending" && (metadata?.title.isEmpty == true || metadata?.matches(row.name) == true))
        let published = !pending && (row.replay || row.availability == "blocked")
        let verified = published && row.availability != "blocked" && metadata?.hasDuration == true && metadata?.matches(row.name) == true
        return WebCourseLesson(id: id, name: row.name, subject: "", stage: "", chapter: "", kind: "living",
                               published: published, durationSeconds: verified ? metadata?.durationSeconds : nil,
                               watchedPercent: verified ? (metadata?.watchedPercent ?? 0) : 0,
                               markedFinished: false, requiresDuration: published)
    }

    private func finishReplayURL(_ url: URL?, availability: String? = nil) {
        let continuation = replayURLContinuation
        replayURLContinuation = nil
        replayURLRequestID = nil
        continuation?.resume(returning: XuechengReplayTarget(url: url, availability: availability))
    }
    private func replayURL(for index: Int) async -> XuechengReplayTarget {
        if browser != nil {
            let source = """
            const previous = window.open;
            let captured = null;
            const bridge = window.__studyCourseBridge;
            const intercept = (value) => {
              try { const u = new URL(value, location.href);
                if (u.origin === location.origin && u.pathname === '/backWindow') { captured = u.href; return null; }
              } catch {}
              return null;
            };
            window.open = intercept;
            const restore = () => { if (window.open === intercept) window.open = previous; };
            bridge.restoreReplayOpen = restore;
            try {
              await window.studyXuechengCrawler?.open(index);
              for (let i = 0; i < 80; i++) {
                const availability = window.studyXuechengCrawler?.replayState(index);
                if (availability) return {availability};
                if (captured) return {url: captured};
                await new Promise(r => setTimeout(r, 100));
              }
              return {};
            } finally {
              restore();
              if (bridge.restoreReplayOpen === restore) delete bridge.restoreReplayOpen;
            }
            """
            guard let value = try? await evaluate(source, arguments: ["index": index]) as? [String: Any] else { return XuechengReplayTarget() }
            return XuechengReplayTarget(url: (value["url"] as? String).flatMap(URL.init(string:)), availability: value["availability"] as? String)
        }
        return await withCheckedContinuation { continuation in
            let requestID = UUID()
            replayURLRequestID = requestID
            replayURLContinuation = continuation
            Task { @MainActor in
                _ = try? await evaluate("return (await window.studyXuechengCrawler?.open(index)) === true;", arguments: ["index": index])
                for _ in 0..<80 {
                    guard replayURLRequestID == requestID else { return }
                    if let availability = try? await evaluate("return window.studyXuechengCrawler?.replayState(index);", arguments: ["index": index]) as? String {
                        if replayURLRequestID == requestID { finishReplayURL(nil, availability: availability) }
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if replayURLRequestID == requestID { finishReplayURL(nil) }
            }
        }
    }
    private func finishReplayMetadata(_ metadata: XuechengReplayMetadata?) {
        let continuation = replayMetadataContinuation
        replayMetadataContinuation = nil
        replayMetadataRequestID = nil
        replayWebView?.stopLoading()
        replayWebView?.configuration.userContentController.removeScriptMessageHandler(forName: "replayMetadata")
        replayWebView = nil
        continuation?.resume(returning: metadata)
    }
    private func readReplayMetadata(at url: URL) async throws -> XuechengReplayMetadata? {
        guard url.scheme == "https", Self.isXuechengHost(url.host),
              url.path == "/backWindow" else { return nil }
        if let browser { return try await browserReplayMetadata(browser, url: url) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        configuration.userContentController.add(self, name: "replayMetadata")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.replayScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let replay = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        replayWebView = replay
        return await withCheckedContinuation { continuation in
            let requestID = UUID()
            replayMetadataRequestID = requestID
            replayMetadataContinuation = continuation
            replay.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if replayMetadataRequestID == requestID { finishReplayMetadata(nil) }
            }
        }
    }
    func tick(autoRefresh: Bool) {
        if browser != nil { tickBrowser(autoRefresh: autoRefresh); return }
        guard !stopped, !busy, let url = webView.url,
              WebLessonTiming.isSameWebsite(current: url, target: targetURL),
              (isGenericSite || WebLessonTiming.isOnTargetPage(current: url, target: targetURL)) else { return }
        if attemptedURL == nil {
            attemptedURL = url.absoluteString
            if isGenericSite { scanIfChanged() } else { refresh() }
        } else if autoRefresh, let lastRefresh, Date().timeIntervalSince(lastRefresh) >= 300 {
            refresh()
        } else if isGenericSite {
            // Generic mode re-reads only when the page has produced new responses.
            scanIfChanged()
        }
    }
    private func scanIfChanged() {
        Task { @MainActor in
            guard !stopped, !busy else { return }
            let value = try? await evaluate("return String(window.studyGenericCrawler ? window.studyGenericCrawler.revision() : -1);", arguments: [:])
            guard !stopped, !busy, let text = value as? String, let revision = Int(text),
                  revision > 0, revision != capturedRevision else { return }
            capturedRevision = revision
            refresh(forceCatalog: false)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation = UUID(); busy = false; attemptedURL = nil; capturedRevision = -1
        finishReplayURL(nil)
        finishReplayMetadata(nil)
        if !isGenericSite { result = nil }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The site sends unauthenticated deep links back to its root; retry a bounded number of times.
        guard opened, let current = webView.url, targetURL.path != "/", current.path == "/",
              WebLessonTiming.isSameWebsite(current: current, target: targetURL),
              redirectAttempts < 2 else { return }
        redirectAttempts += 1
        webView.load(URLRequest(url: targetURL))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status = "网页加载失败：\(error.localizedDescription)" }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if replayURLContinuation != nil, let url = navigationAction.request.url,
           url.scheme == "https", Self.isXuechengHost(url.host),
           url.path == "/backWindow" {
            finishReplayURL(url)
            return nil
        }
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, WebLessonTiming.websiteURL(url.absoluteString) != nil { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// The import sheet follows the display it opens on instead of a fixed 1120×820 frame.
private enum WebImportLayout {
    static var size: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 900)
        return CGSize(width: min(max(visible.width - 80, 960), 1520),
                      height: min(max(visible.height - 40, 680), 1120))
    }
}

struct WebCourseImportSheet: View {
    @Bindable var store: PlannerStore
    @Environment(\.dismiss) private var dismiss
    @State private var reader = WebLessonReader()
    @State private var selected = Set<String>()
    @State private var autoRefresh = true
    @State private var lastOffered = Set<String>()
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 90, to: Date())!
    @State private var message = ""
    @State private var saving = false
    @State private var searchText = ""
    @State private var matchingIDs: Set<String>?
    @State private var filteredRequest: SearchRequest?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private struct SearchRequest: Hashable { var query: String; var refreshedAt: Date? }
    private var searchRequest: SearchRequest { .init(query: searchText, refreshedAt: reader.lastRefresh) }
    private var filtering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filteredRequest != searchRequest
    }
    private var chosen: [WebCourseSnapshot] { reader.result?.snapshots.filter { selected.contains($0.identityKey) } ?? [] }
    private var visibleSnapshots: [WebCourseSnapshot] {
        let snapshots = reader.result?.snapshots ?? []
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return snapshots }
        guard !filtering, let matchingIDs else { return [] }
        return snapshots.filter { matchingIDs.contains($0.identityKey) }
    }
    private var visibleSelectableIDs: Set<String> {
        Set(visibleSnapshots.filter { $0.importProblem == nil }.map(\.identityKey))
    }
    var body: some View {
        let layout = WebImportLayout.size
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从网站导入课程").font(.title2.bold())
                    Text("在默认浏览器登录，在这里核对课节并保存计划").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                TextField("网站地址（仅 HTTPS）", text: $reader.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reader.loadAddress() }
                Button("在默认浏览器打开") { reader.loadAddress() }
                Button("恢复默认地址") { reader.useDefaultAddress() }
                    .disabled(reader.address == WebLessonReader.defaultAddress)
            }
            HStack {
                if reader.busy { ProgressView().controlSize(.small) }
                Text(reader.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("读取浏览器当前课程") { reader.refresh() }.disabled(reader.busy)
                Toggle("每 5 分钟刷新", isOn: $autoRefresh).toggleStyle(.checkbox)
            }
            browserInstructions
            courseSidebar.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if saving { ProgressView("正在导入并保存计划…").controlSize(.small) }
                Text(message).foregroundStyle(.red).font(.caption)
                Spacer()
                Text("已选 \(chosen.count) 门").font(.caption).foregroundStyle(.secondary)
                Button("导入并生成计划") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || reader.busy || filtering || !(reader.result?.issues.isEmpty ?? false))
            }
        }.padding(20).frame(width: layout.width, height: layout.height)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { reader.open() }
        .onDisappear { reader.stop() }
        .task(id: searchRequest) { await filterCourses() }
        .onReceive(timer) { _ in if !saving { reader.tick(autoRefresh: autoRefresh) } }
        .onChange(of: reader.lastRefresh) { _, _ in
            guard !saving else { return }
            // Re-identifying the same courses must not clear a selection the user already made.
            let offered = Set(reader.result?.snapshots.filter { $0.importProblem == nil }.map(\.identityKey) ?? [])
            selected = WebCourseImportSelection.refreshed(selected: selected, previouslyOffered: lastOffered, offered: offered)
            lastOffered = offered
        }
    }
    private var courseSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("抓取结果", systemImage: "list.bullet.rectangle").font(.headline)
                Spacer()
                if let result = reader.result { Text("\(result.snapshots.count) 门").font(.caption).foregroundStyle(.secondary) }
            }
            if let result = reader.result {
                DatePicker("新课程截止日", selection: $deadline, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                HStack {
                    TextField("搜索课程、课节或来源网站", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Button("清除筛选") { searchText = "" }.disabled(searchText.isEmpty)
                    if filtering { ProgressView().controlSize(.small) }
                }
                HStack {
                    Text(filtering ? "正在筛选课程…" : "显示 \(visibleSnapshots.count)/\(result.snapshots.count) 门")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("选中结果") { selected.formUnion(visibleSelectableIDs) }
                        .disabled(filtering || visibleSelectableIDs.isEmpty || visibleSelectableIDs.isSubset(of: selected))
                    Button("只选结果") { selected = visibleSelectableIDs }
                        .disabled(filtering || visibleSelectableIDs.isEmpty || selected == visibleSelectableIDs)
                        .help("只勾选当前筛选中可导入的课程，取消其他课程的选择")
                    Button("清空选择") { selected.removeAll() }.disabled(selected.isEmpty)
                }
                .disabled(reader.busy)
                let visibleIDs = Set(visibleSnapshots.map(\.identityKey))
                let hiddenCount = chosen.filter { !visibleIDs.contains($0.identityKey) }.count
                if hiddenCount > 0 && !filtering {
                    Text("另有 \(hiddenCount) 门已选课程不在当前筛选中，导入时会一并保存；可清除筛选查看，或点“只选结果”。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("已发现 \(result.packageCount) 个课程包；\(result.unavailable.count) 项暂不可导入")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if visibleSnapshots.isEmpty && !filtering {
                            ContentUnavailableView("没有匹配的课程", systemImage: "magnifyingglass",
                                                   description: Text("试试课程名、课节关键词或来源网站；清除筛选可查看全部课程。"))
                        }
                        ForEach(visibleSnapshots, id: \.identityKey) { snapshot in
                            courseCard(snapshot)
                        }
                        ForEach(Array(result.unavailable.enumerated()), id: \.offset) { _, item in
                            Label("\(item.name)：\(item.reason)", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(result.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                    .padding(.vertical, 2)
                }
                Text("按来源网站和课程包编号更新；网站观看进度会与应用内已确认记录核对。")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView("等待课程数据", systemImage: "square.stack.3d.up",
                    description: Text("在默认浏览器登录，选中课程标签页，再点击上方“读取浏览器当前课程”。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
    private var browserInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("网页在\(reader.browserName)中打开", systemImage: "arrow.up.forward.app").font(.headline)
            Text("1. 在浏览器登录并选中课程页面。  2. 回到这里读取课程。  3. 核对结果后导入。")
            Text("首次读取请允许系统自动化授权，并在浏览器开发者设置中开启“允许来自 Apple 事件的 JavaScript”。支持 Safari 和提供该接口的 Chrome 系浏览器。")
            if reader.isGenericSite {
                Text("通用网站请先读取一次以开始识别，再在同一标签页进入课程目录。若没有结果，请在网站内返回列表后重新点开课程；完整刷新网页后需重新连接。已识别课程会累加。")
            }
            if reader.isXuechengSite {
                Text("学丞直播回放会临时打开浏览器标签页读取时长，完成后自动关闭；请等待读取完成。")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
    private static func matchingProblem(_ snapshot: WebCourseSnapshot, courses: [Course]) -> String? {
        do { _ = try snapshot.matchingCourseIndices(in: courses); return nil }
        catch { return error.localizedDescription }
    }
    private func courseCard(_ snapshot: WebCourseSnapshot) -> some View {
        let existing = (try? snapshot.matchingCourseIndices(in: store.state.courses))?.first.map { store.state.courses[$0] }
        return VStack(alignment: .leading, spacing: 7) {
            Toggle(snapshot.name, isOn: Binding(get: { selected.contains(snapshot.identityKey) }, set: {
                if $0 { selected.insert(snapshot.identityKey) } else { selected.remove(snapshot.identityKey) }
            }))
            .font(.callout.weight(.semibold))
            .disabled(snapshot.importProblem != nil || reader.busy || filtering)
            if let host = WebCourseImportSearch.websiteLabel(for: snapshot) {
                Label(host, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(snapshot.lessons.count) 节 · 剩余 \(WebLessonTiming.clock(snapshot.remainingSeconds)) / 总计 \(WebLessonTiming.clock(snapshot.totalSeconds))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let existing {
                if existing.isArchived {
                    Text("将恢复已归档课程；从今天排至所选截止日 \(deadline.formatted(date: .abbreviated, time: .omitted))。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("更新已有课程；保留截止日 \(existing.deadline.formatted(date: .abbreviated, time: .omitted))。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !existing.autoScheduleEnabled {
                        Text("此课程已暂停自动排程；导入后可在课程编辑中恢复。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let problem = snapshot.importProblem { Text(problem).font(.caption).foregroundStyle(.orange) }
            if let problem = Self.matchingProblem(snapshot, courses: store.state.courses) {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            ForEach(snapshot.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("查看课节与编排预览") {
                if let candidate = previewState(for: snapshot), let course = candidate.courses.first(where: { $0.webCourse?.matchesIdentity(of: snapshot) == true }) {
                    LessonSchedulePreview(state: candidate, course: course)
                } else {
                    ForEach(snapshot.lessons) { lesson in
                        Text("\(lesson.name) · \(lesson.durationSeconds.map(WebLessonTiming.clock) ?? "时长待定")")
                            .font(.caption)
                    }
                }
            }
            .font(.caption)
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
    }
    private func previewState(for snapshot: WebCourseSnapshot) -> PlannerState? {
        var candidate = store.state
        do {
            try candidate.importWebCourses([snapshot], deadline: deadline, now: Date())
            return candidate
        } catch { return nil }
    }
    private func filterCourses() async {
        let request = searchRequest
        let query = request.query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matchingIDs = nil; filteredRequest = request; return
        }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let snapshots = reader.result?.snapshots ?? []
        let ids = await Task.detached(priority: .userInitiated) {
            WebCourseImportSearch.matchingIDs(query: query, snapshots: snapshots)
        }.value
        guard !Task.isCancelled else { return }
        matchingIDs = ids
        filteredRequest = request
    }
    private func save() {
        guard !saving, !reader.busy, !filtering, reader.result?.issues.isEmpty == true else { return }
        let snapshots = chosen
        guard !snapshots.isEmpty else { message = "请勾选要导入的课程。"; return }
        let importDeadline = deadline
        let importTime = Date()
        saving = true
        message = ""
        Task {
            defer { saving = false }
            let success = await store.change { state in
                try state.importWebCourses(snapshots, deadline: importDeadline, now: importTime)
            }
            if success { dismiss() } else { message = store.errorMessage ?? "保存失败" }
        }
    }
}
