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

private struct XuechengCatalog: Decodable {
    struct Row: Decodable {
        let name: String
        let replay: Bool
        let previouslyWatched: Bool
        let key: String?
    }
    let courseID: String
    let name: String
    let rows: [Row]
}

private struct XuechengReplayMetadata: Decodable {
    let title: String
    let durationSeconds: Double
    let watchedPercent: Double?
}

@MainActor @Observable
final class WebLessonReader: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    /// Built-in entry point; the editable address bar can point the same reader at any other HTTPS page.
    static let defaultAddress = "https://www.kaoyanvip.cn/appmanage/my/mycourse"
    static let defaultURL = URL(string: WebLessonReader.defaultAddress)!
    var result: WebCourseAccount?
    var status = "登录网站并进入“我的课程”后，会自动抓取账号下全部课程包。"
    var busy = false
    var lastRefresh: Date?
    var webView: WKWebView!
    /// Address bar text; `targetURL` is the address the reader currently reads.
    var address = WebLessonReader.defaultAddress
    private(set) var targetURL = WebLessonReader.defaultURL
    private var generation = UUID()
    private var stopped = false
    private var opened = false
    private var attemptedURL: String?
    private var redirectAttempts = 0
    private var replayURLContinuation: CheckedContinuation<URL?, Never>?
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
    var isGenericSite: Bool { targetURL.host?.lowercased().hasSuffix("kaoyanvip.cn") != true }
    var isXuechengSite: Bool { Self.isXuechengHost(targetURL.host) }
    private(set) var capturedResponses = 0
    private var capturedRevision = -1
    static var script: String { resource("CourseCrawler") }
    /// Injected before any page script runs, so the sniffer can wrap fetch and XMLHttpRequest in time.
    static var genericScript: String { resource("GenericCrawler") }
    static var xuechengScript: String { resource("XuechengCrawler") }
    static var replayScript: String { resource("XuechengReplay") }
    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return source
    }
    override init() {
        super.init()
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
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "replayMetadata" {
            guard message.webView === replayWebView,
                  message.frameInfo.securityOrigin.host == "view.csslcloud.net",
                  let body = message.body as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: body),
                  let metadata = try? JSONDecoder().decode(XuechengReplayMetadata.self, from: data),
                  !metadata.title.isEmpty, metadata.durationSeconds > 0, metadata.durationSeconds <= 36_000 else { return }
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
        webView.load(URLRequest(url: url))
    }
    func stop() {
        stopped = true; generation = UUID(); busy = false
        finishReplayURL(nil)
        finishReplayMetadata(nil)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "courseStatus")
        webView.stopLoading(); webView.loadHTMLString("", baseURL: nil)
    }
    func refresh(forceCatalog: Bool = true) {
        guard !busy, !stopped, let page = webView.url,
              WebLessonTiming.isSameWebsite(current: page, target: targetURL) else {
            if !busy { status = "请先登录并进入“我的课程”，登录成功后会自动抓取。" }
            return
        }
        busy = true; generation = UUID()
        if forceCatalog { replayAttempts.removeAll() }
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
    private func readAdapted(generation current: UUID) async {
        do {
            let value = try await webView.callAsyncJavaScript("return JSON.stringify(await window.studyCourseCrawler.crawl(null));", arguments: [:], in: nil, contentWorld: .page)
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
    private func readGeneric(generation current: UUID, page: URL, forceCatalog: Bool) async {
        do {
            var catalog: XuechengCatalog?
            if Self.isXuechengHost(page.host), page.path == "/detail" {
                status = "正在按顺序读取各层课程目录，请等待自动读取完成…"
            }
            if Self.isXuechengHost(page.host), page.path == "/detail",
               let value = try await webView.callAsyncJavaScript("return JSON.stringify(await window.studyXuechengCrawler?.catalog(force));", arguments: ["force": forceCatalog], in: nil, contentWorld: .page) as? String,
               let data = value.data(using: .utf8) {
                catalog = try? JSONDecoder().decode(XuechengCatalog.self, from: data)
            }
            guard !stopped, generation == current else { return }
            guard let value = try await webView.callAsyncJavaScript("return JSON.stringify({title: document.title || '', payloads: window.studyGenericCrawler ? window.studyGenericCrawler.snapshot() : [], revision: window.studyGenericCrawler?.revision() ?? -1});", arguments: [:], in: nil, contentWorld: .page) as? String,
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
                let course = await collectXuecheng(catalog, page: page, baseSnapshots: snapshots, generation: current)
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
                    status = "已捕获 \(payloads.count) 个数据接口，但没有识别到课程结构。请在该网站里打开「我的课程」或课程详情页，等课节列表出现后再点「重新识别课程」。"
                }
            } else {
                // Courses read from earlier pages are kept: a site usually needs one visit per course.
                let merged = Self.merged(result?.snapshots ?? [], with: snapshots)
                result = WebCourseAccount(snapshots: merged, unavailable: [], issues: [], packageCount: merged.count)
                lastRefresh = Date()
                if let catalog, !catalog.rows.isEmpty {
                    let course = merged.first { $0.packageID == "generic:" + catalog.courseID }
                    let missing = course?.unknownDurations ?? 0
                    status = missing == 0
                        ? "已读取 \(catalog.rows.count) 个直播条目；网站未提供的观看进度按 0% 计。请核对后生成计划。"
                        : "已读取 \(catalog.rows.count) 个直播条目，其中 \(missing) 个回放未取得时长；请重新抓取。"
                } else {
                    status = "本轮识别出 \(snapshots.count) 门课程，累计 \(merged.count) 门；继续打开其他课程会自动累加，核对后生成计划。"
                }
            }
        } catch {
            guard !stopped, generation == current else { return }
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
            if byID.updateValue(snapshot, forKey: snapshot.packageID) == nil { order.append(snapshot.packageID) }
        }
        for snapshot in fresh {
            if var previous = byID[snapshot.packageID] {
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
                        if better.durationSeconds == nil { better.durationSeconds = old.durationSeconds }
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
                if snapshot.sourceURL.contains("ixuecheng.cn/detail?") { previous.sourceURL = snapshot.sourceURL }
                if snapshot.sourceURL.contains("ixuecheng.cn/detail?") {
                    previous.expectedOutlines = snapshot.expectedOutlines
                    previous.fetchedOutlines = snapshot.fetchedOutlines
                    previous.issues = snapshot.issues
                }
                previous.fetchedAt = snapshot.fetchedAt
                byID[snapshot.packageID] = previous
            } else {
                byID[snapshot.packageID] = snapshot
                order.append(snapshot.packageID)
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
                                  baseSnapshots: [WebCourseSnapshot], generation current: UUID) async -> WebCourseSnapshot {
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
            if row.replay && metadata == nil && !replayAttempts.contains(id) && !stopped && generation == current {
                replayAttempts.insert(id)
                status = "正在进入直播回放 \(index + 1)/\(catalog.rows.count)：\(row.name)"
                if let url = await replayURL(for: index), !stopped, generation == current {
                    let candidate = await readReplayMetadata(at: url)
                    if let candidate,
                       candidate.title.filter({ !$0.isWhitespace }) == row.name.filter({ !$0.isWhitespace }) {
                        metadata = candidate
                        replayCache[id] = candidate
                    }
                }
            }
            lessons.append(WebCourseLesson(id: id, name: row.name, subject: "", stage: "", chapter: "",
                                           kind: "living", published: row.replay,
                                           durationSeconds: metadata?.durationSeconds,
                                           watchedPercent: metadata?.watchedPercent ?? 0,
                                           markedFinished: false, requiresDuration: row.replay))
            guard !stopped, generation == current else { break }
            if row.replay {
                if metadata?.durationSeconds != nil { resolved += 1 } else { unresolved += 1 }
            }
            let partial = xuechengSnapshot(catalog, page: page, lessons: lessons, complete: false)
            let merged = Self.merged(result?.snapshots ?? [], with: Self.merged(baseSnapshots, with: [partial]))
            result = WebCourseAccount(snapshots: merged, unavailable: [],
                                      issues: ["学丞直播回放时长仍在读取，请等待完成。"], packageCount: merged.count)
            status = "已处理直播条目 \(index + 1)/\(catalog.rows.count)；取得时长 \(resolved) 个，待定 \(unresolved) 个。"
        }
        return xuechengSnapshot(catalog, page: page, lessons: lessons,
                                complete: !stopped && generation == current && lessons.count == catalog.rows.count)
    }

    private func finishReplayURL(_ url: URL?) {
        let continuation = replayURLContinuation
        replayURLContinuation = nil
        replayURLRequestID = nil
        continuation?.resume(returning: url)
    }
    private func replayURL(for index: Int) async -> URL? {
        await withCheckedContinuation { continuation in
            let requestID = UUID()
            replayURLRequestID = requestID
            replayURLContinuation = continuation
            Task { @MainActor in
                let clicked = try? await webView.callAsyncJavaScript("return (await window.studyXuechengCrawler?.open(index)) === true;", arguments: ["index": index], in: nil, contentWorld: .page) as? Bool
                if clicked != true, replayURLRequestID == requestID { finishReplayURL(nil); return }
                try? await Task.sleep(for: .seconds(8))
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
    private func readReplayMetadata(at url: URL) async -> XuechengReplayMetadata? {
        guard url.scheme == "https", Self.isXuechengHost(url.host),
              url.path == "/backWindow" else { return nil }
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
            let value = try? await webView.callAsyncJavaScript("return String(window.studyGenericCrawler ? window.studyGenericCrawler.revision() : -1);", arguments: [:], in: nil, contentWorld: .page)
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

private struct LessonWebsite: NSViewRepresentable {
    let reader: WebLessonReader
    func makeNSView(context: Context) -> WKWebView { reader.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
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
    @State private var showWebsite = true
    @State private var lastOffered = Set<String>()
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 90, to: Date())!
    @State private var message = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var chosen: [WebCourseSnapshot] { reader.result?.snapshots.filter { selected.contains($0.packageID) } ?? [] }
    var body: some View {
        let layout = WebImportLayout.size
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("从网站导入课程").font(.title2.bold())
                    Text("登录、读取课节、核对编排，再保存计划").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                TextField("网站地址（仅 HTTPS）", text: $reader.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { reader.loadAddress() }
                Button("打开") { reader.loadAddress() }
                Button("恢复默认地址") { reader.useDefaultAddress() }
                    .disabled(reader.address == WebLessonReader.defaultAddress)
            }
            HStack {
                if reader.busy { ProgressView().controlSize(.small) }
                Text(reader.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(reader.isGenericSite ? "重新识别课程" : "重新抓取全部课程") { reader.refresh() }.disabled(reader.busy)
                Toggle("每 5 分钟刷新", isOn: $autoRefresh).toggleStyle(.checkbox)
            }
            HStack(alignment: .top, spacing: 14) {
                courseSidebar.frame(width: min(415, layout.width * 0.35))
                websitePane
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text(message).foregroundStyle(.red).font(.caption)
                Spacer()
                Text("已选 \(chosen.count) 门").font(.caption).foregroundStyle(.secondary)
                Button("导入并生成计划") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || reader.busy || !(reader.result?.issues.isEmpty ?? false))
            }
        }.padding(20).frame(width: layout.width, height: layout.height)
        .onAppear { reader.open() }
        .onDisappear { reader.stop() }
        .onReceive(timer) { _ in reader.tick(autoRefresh: autoRefresh) }
        .onChange(of: reader.lastRefresh) { _, _ in
            // Re-identifying the same courses must not clear a selection the user already made.
            let offered = Set(reader.result?.snapshots.filter { $0.importProblem == nil }.map(\.packageID) ?? [])
            if offered != lastOffered { lastOffered = offered; selected = offered }
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
                Text("已发现 \(result.packageCount) 个课程包；\(result.unavailable.count) 项暂不可导入")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(result.snapshots, id: \.packageID) { snapshot in
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
                Text("按课程包编号更新；网站观看进度会与应用内已确认记录核对。")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ContentUnavailableView("等待课程数据", systemImage: "square.stack.3d.up",
                    description: Text("在右侧登录并打开课程目录。直播回放课程还需进入回放读取时长。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
    private var websitePane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("网站页面", systemImage: "globe").font(.headline)
                Spacer()
                Toggle("显示网页", isOn: $showWebsite).toggleStyle(.checkbox)
            }
            Text(reader.isXuechengSite
                 ? "打开一门课程后会自动逐层读取章节和回放；请等待读取完成后再切换课程。"
                 : reader.isGenericSite
                    ? "登录后进入“我的课程”，逐门打开课程目录；识别结果会累加到左侧。"
                    : "登录后自动遍历课程包、科目与课节。网站进度可能延迟约 5 分钟。")
                .font(.caption).foregroundStyle(.secondary)
            // Keep the WebView mounted so login and captured responses survive a collapse.
            LessonWebsite(reader: reader)
                .frame(minHeight: showWebsite ? 300 : 1, maxHeight: showWebsite ? .infinity : 1)
                .opacity(showWebsite ? 1 : 0)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func courseCard(_ snapshot: WebCourseSnapshot) -> some View {
        let existing = store.state.courses.first { $0.webCourse?.packageID == snapshot.packageID }
        return VStack(alignment: .leading, spacing: 7) {
            Toggle(snapshot.name, isOn: Binding(get: { selected.contains(snapshot.packageID) }, set: {
                if $0 { selected.insert(snapshot.packageID) } else { selected.remove(snapshot.packageID) }
            }))
            .font(.callout.weight(.semibold))
            .disabled(snapshot.importProblem != nil)
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
            ForEach(snapshot.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            DisclosureGroup("查看课节与编排预览") {
                if let candidate = previewState(for: snapshot), let course = candidate.courses.first(where: { $0.webCourse?.packageID == snapshot.packageID }) {
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
    private func save() {
        let snapshots = chosen
        let success = store.change { state in
            try state.importWebCourses(snapshots, deadline: deadline, now: Date())
        }
        if success { dismiss() } else { message = store.errorMessage ?? "保存失败" }
    }
}
