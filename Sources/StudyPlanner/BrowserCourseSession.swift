import AppKit
import Carbon
import StudyCore

enum BrowserCourseError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

/// Apple events stay off the main thread and target only the explicitly connected tab.
actor BrowserCourseSession {
    private var pid: pid_t = 0
    private var kind: PlaybackScripting = .safari
    private var application: SupervisedApplication?
    private var tab: NSAppleEventDescriptor?
    private var session = UUID().uuidString
    private var origin = ""
    private var pageURL: URL?

    static func literal(_ text: String) -> String {
        String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    }

    static func failure(_ error: Error, kind: PlaybackScripting) -> BrowserCourseError {
        if let error = error as? BrowserCourseError { return error }
        let code = (error as NSError).code
        if code == -1743 || code == -1744 {
            return .message("请在“系统设置 → 隐私与安全性 → 自动化 → 学习日程”允许读取浏览器，再点“读取浏览器当前课程”。")
        }
        if code == -600 { return .message("浏览器已退出，请重新打开网站。") }
        let help = kind == .safari
            ? "请在 Safari 设置中开启网页开发者功能，再开启“允许来自 Apple 事件的 JavaScript”。"
            : "请在浏览器“查看 → 开发者”菜单开启“允许来自 Apple 事件的 JavaScript”。"
        return .message("浏览器读取失败（错误码 \(code)）。" + help)
    }

    func connect(application: SupervisedApplication, pid: pid_t, target: URL) throws -> URL {
        guard let kind = application.scripting, kind == .safari || kind == .chromium else {
            throw BrowserCourseError.message("当前默认浏览器不提供课程读取接口。可将 Safari 或支持 Apple 事件的 Chrome 系浏览器设为默认浏览器后重试。")
        }
        switch PlaybackStateReader.permission(pid: pid, askUser: true) {
        case .granted: break
        case .notRunning: throw Self.failure(NSError(domain: NSOSStatusErrorDomain, code: -600), kind: kind)
        case .failed(let code): throw Self.failure(NSError(domain: NSOSStatusErrorDomain, code: Int(code)), kind: kind)
        case .denied, .consentRequired:
            throw Self.failure(NSError(domain: NSOSStatusErrorDomain, code: -1743), kind: kind)
        }
        do {
            let windows = try PlaybackStateReader.send(pid: pid, direct: PlaybackStateReader.object("cwin"))
            guard let window = windows.atIndex(1) else { throw BrowserCourseError.message("请先在默认浏览器打开课程页面。") }
            let selectedTab = try PlaybackStateReader.send(pid: pid, direct: PlaybackStateReader.object("prop", container: window,
                property: kind == .safari ? "cTab" : "acTa"))
            if self.pid == pid, self.kind == kind,
               (try? execute("String(window.__studyCourseBridge?.session === \(Self.literal(session)))", in: selectedTab)) == "true" {
                let page = try url(of: selectedTab)
                guard WebLessonTiming.isSameWebsite(current: page, target: target) else {
                    throw BrowserCourseError.message("浏览器当前标签页不是地址栏中的网站。")
                }
                tab = selectedTab
                return page
            }
            stop()
            self.application = application; self.pid = pid; self.kind = kind; tab = selectedTab
            return try prepare(target: target)
        } catch { throw Self.failure(error, kind: kind) }
    }

    private func url(of tab: NSAppleEventDescriptor) throws -> URL {
        let value = try PlaybackStateReader.send(pid: pid, direct: PlaybackStateReader.object("prop", container: tab,
            property: kind == .safari ? "pURL" : "URL ")).stringValue ?? ""
        guard let url = WebLessonTiming.websiteURL(value) else { throw BrowserCourseError.message("请在浏览器进入 HTTPS 课程页面。") }
        return url
    }

    private func execute(_ source: String, in tab: NSAppleEventDescriptor) throws -> String {
        let result: NSAppleEventDescriptor
        if kind == .safari {
            result = try PlaybackStateReader.send(pid: pid, eventClass: "sfri", eventID: "dojs",
                direct: .init(string: source), parameter: ("dcnm", tab), timeout: 5)
        } else {
            result = try PlaybackStateReader.send(pid: pid, eventClass: "CrSu", eventID: "ExJa",
                direct: tab, parameter: ("JvSc", .init(string: source)), timeout: 5)
        }
        return result.stringValue ?? ""
    }

    /// A navigation must be explicitly reconnected; tab indexes can change in Safari.
    /// Never silently reattach to whichever tab later occupies the same position.
    func currentPage() throws -> URL {
        guard let tab, let pageURL else { throw BrowserCourseError.message("请先点击“读取浏览器当前课程”。") }
        do {
            guard try execute("String(window.__studyCourseBridge?.session === \(Self.literal(session)))", in: tab) == "true",
                  WebLessonTiming.isSameWebsite(current: try url(of: tab), target: pageURL) else {
                throw BrowserCourseError.message("课程页面已重新加载、关闭或移动，请选中课程标签页后重新点击“读取浏览器当前课程”。")
            }
            return try url(of: tab)
        } catch { throw Self.failure(error, kind: kind) }
    }

    private func prepare(target: URL) throws -> URL {
        guard let tab else { throw BrowserCourseError.message("未找到课程标签页。") }
        let page = try url(of: tab)
        guard WebLessonTiming.isSameWebsite(current: page, target: target) else {
            throw BrowserCourseError.message("浏览器当前标签页不是地址栏中的网站。请选中该网站的课程页面后再读取。")
        }
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)!
        components.path = ""; components.query = nil; components.fragment = nil
        origin = components.string!
        let source = Self.bootstrap(session: session, origin: origin)
        guard try execute(source, in: tab) == "ready" else { throw BrowserCourseError.message("课程页面已切换，请重新读取。") }
        pageURL = page
        return page
    }

    static func bootstrap(session: String, origin: String) -> String {
        """
        (() => {
          if (location.origin !== \(literal(origin))) return 'wrong-site';
          const old = window.__studyCourseBridge;
          if (old?.session === \(literal(session))) return 'ready';
          old?.stop?.();
          const originals = {fetch: window.fetch, open: XMLHttpRequest.prototype.open, send: XMLHttpRequest.prototype.send};
          const bridge = {session: \(literal(session)), jobs: Object.create(null)};
          window.__studyCourseBridge = bridge;
          bridge.stop = () => {
            bridge.jobs = Object.create(null);
            bridge.restoreReplayOpen?.();
            if (window.fetch === bridge.fetch) window.fetch = originals.fetch;
            if (XMLHttpRequest.prototype.open === bridge.open) XMLHttpRequest.prototype.open = originals.open;
            if (XMLHttpRequest.prototype.send === bridge.send) XMLHttpRequest.prototype.send = originals.send;
            delete window.studyGenericCrawler;
            delete window.studyCourseCrawler;
            delete window.studyXuechengCrawler;
            delete window.__studyCourseBridge;
          };
          return 'ready';
        })()
        """
    }

    func install(_ scripts: String) throws {
        guard let tab else { return }
        _ = try currentPage()
        _ = try execute("""
        (() => {
          if (window.__studyCourseBridge?.session !== \(Self.literal(session))) return '';
          \(scripts)
          const b = window.__studyCourseBridge;
          b.fetch = window.fetch; b.open = XMLHttpRequest.prototype.open; b.send = XMLHttpRequest.prototype.send;
          return 'installed';
        })()
        """, in: tab)
    }

    static func jobScript(body: String, argumentsJSON: String, id: String, session: String) -> String {
        """
        (() => {
          const bridge = window.__studyCourseBridge;
          if (bridge?.session !== \(literal(session))) return 'changed';
          const job = {done: false, href: location.href}; bridge.jobs[\(literal(id))] = job;
          const args = \(argumentsJSON);
          Promise.resolve().then(async () => { const {force, index} = args; \(body) })
            .then(value => { job.value = value ?? null; job.done = true; })
            .catch(() => { job.failed = true; job.done = true; });
          return 'started';
        })()
        """
    }

    func evaluate(_ body: String, argumentsJSON: String = "{}") async throws -> Data {
        _ = try currentPage()
        guard let tab else { throw CancellationError() }
        let activeSession = session, id = UUID().uuidString
        do {
            guard try execute(Self.jobScript(body: body, argumentsJSON: argumentsJSON, id: id, session: activeSession), in: tab) == "started" else {
                throw BrowserCourseError.message("课程页面已变化，请重新读取。")
            }
            defer {
                _ = try? execute("if (window.__studyCourseBridge?.session === \(Self.literal(activeSession))) delete window.__studyCourseBridge.jobs[\(Self.literal(id))]; 'done';", in: tab)
            }
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                try Task.checkCancellation()
                guard session == activeSession else { throw CancellationError() }
                let json = try execute("""
                (() => { const b = window.__studyCourseBridge, j = b?.jobs[\(Self.literal(id))];
                  return JSON.stringify(b?.session === \(Self.literal(activeSession)) && j?.href === location.href ? j : null);
                })()
                """, in: tab)
                guard let data = json.data(using: .utf8), let packet = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any] else {
                    throw BrowserCourseError.message("课程页面已重新加载，请重新读取。")
                }
                if packet["done"] as? Bool == true {
                    guard packet["failed"] as? Bool != true else { throw BrowserCourseError.message("课程读取失败。请确认已登录、目录已加载，再重新读取；网站结构变化也可能导致失败。") }
                    return try JSONSerialization.data(withJSONObject: packet["value"] ?? NSNull(), options: .fragmentsAllowed)
                }
                try await Task.sleep(for: .milliseconds(350))
            }
            throw BrowserCourseError.message("课程读取超时，请重新读取。")
        } catch { throw Self.failure(error, kind: kind) }
    }

    func stop() {
        if let tab {
            _ = try? execute("if (window.__studyCourseBridge?.session === \(Self.literal(session))) window.__studyCourseBridge.stop(); 'stopped';", in: tab)
        }
        tab = nil; pageURL = nil; session = UUID().uuidString
    }

    /// Replay URLs remain in memory. Only verified title/duration/progress leave this method.
    func readReplay(url: URL, script: String) async throws -> Data? {
        guard let application, let pageURL,
              WebLessonTiming.isSameWebsite(current: url, target: pageURL), url.path == "/backWindow" else { return nil }
        let activeSession = session, replayPID = pid
        // Scripting dictionaries differ between Safari and Chromium; both support make-tab.
        func appleString(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        let source = "tell application id \(appleString(application.bundleID)) to make new tab at end of tabs of front window with properties {URL:\(appleString(url.absoluteString))}"
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: source) else { return nil }
        let replayTab = scriptObject.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let marker = UUID().uuidString
        var expected = url
        var installed = false
        let metadataScript = script.replacingOccurrences(of: "window.webkit?.messageHandlers?.replayMetadata?.postMessage(metadata);",
                                                         with: "window.__studyReplayMetadata = metadata;")
        defer {
            // Never close a user tab that moved into the old tab's position.
            if pid == replayPID,
               (try? execute("String(window.__studyReplayOwner === \(Self.literal(marker)))", in: replayTab)) == "true" {
                _ = try? PlaybackStateReader.send(pid: pid, eventID: "clos", direct: replayTab)
            }
        }
        for _ in 0..<80 {
            guard session == activeSession else { return nil }
            try Task.checkCancellation()
            if let current = try? self.url(of: replayTab), current == expected {
                // The tab was just created for this exact URL, never a pre-existing tab.
                _ = try execute("window.__studyReplayOwner = \(Self.literal(marker)); 'owned';", in: replayTab)
                if current.host == "view.csslcloud.net" {
                    if !installed { _ = try execute(metadataScript + "\n'ready';", in: replayTab); installed = true }
                    let json = try execute("JSON.stringify(window.__studyReplayMetadata ?? null)", in: replayTab)
                    if json != "null", let data = json.data(using: .utf8) { return data }
                } else {
                    let value = try execute("""
                    (() => { for (const f of document.querySelectorAll('iframe')) {
                      try { const u = new URL(f.src, location.href);
                        if (u.protocol === 'https:' && u.hostname === 'view.csslcloud.net') return u.href;
                      } catch {}
                    } return ''; })()
                    """, in: replayTab)
                    if let frame = WebLessonTiming.websiteURL(value), frame.host == "view.csslcloud.net" {
                        _ = try PlaybackStateReader.send(pid: pid, eventID: "setd",
                            direct: PlaybackStateReader.object("prop", container: replayTab, property: kind == .safari ? "pURL" : "URL "),
                            parameter: ("data", .init(string: frame.absoluteString)))
                        expected = frame
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}
