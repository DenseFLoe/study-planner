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
    private var managedWindowID: Int32?
    private var managedOwner: String?

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

    func stop(closeManaged: Bool = true) {
        if let tab {
            _ = try? execute("if (window.__studyCourseBridge?.session === \(Self.literal(session))) window.__studyCourseBridge.stop(); 'stopped';", in: tab)
            if closeManaged, let owner = managedOwner,
               (try? execute("String(window.name === \(Self.literal(owner)))", in: tab)) == "true" {
                _ = try? PlaybackStateReader.send(pid: pid, eventID: "clos", direct: tab)
            }
        }
        tab = nil; pageURL = nil; managedWindowID = nil; managedOwner = nil; session = UUID().uuidString
    }

    private static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    /// A dedicated window has a stable ID; never repurpose the user's current tab.
    func openManaged(application: SupervisedApplication, pid: pid_t, target: URL,
                     credentials: @Sendable () throws -> WebsiteCredentials?, allowPermissionPrompt: Bool) async throws -> URL {
        guard let site = CourseWebsite.identify(target), let kind = application.scripting,
              kind == .safari || kind == .chromium else {
            throw WebsiteUpdateError.message("自动更新需要将 Safari 或支持 Apple 事件的 Chrome 系浏览器设为默认浏览器。")
        }
        guard case .granted = PlaybackStateReader.permission(pid: pid, askUser: allowPermissionPrompt) else {
            throw WebsiteUpdateError.message("请点“立即更新”并允许浏览器自动化；还需在浏览器中开启来自 Apple 事件的 JavaScript。")
        }
        stop()
        self.application = application; self.pid = pid; self.kind = kind
        let command = kind == .safari
            ? "make new document with properties {URL:\(Self.appleString(target.absoluteString))}\nreturn id of front window"
            : "set w to make new window\nset URL of active tab of w to \(Self.appleString(target.absoluteString))\nreturn id of w"
        var error: NSDictionary?
        let script = NSAppleScript(source: "tell application id \(Self.appleString(application.bundleID))\n\(command)\nend tell")
        guard let window = script?.executeAndReturnError(&error), error == nil, window.int32Value != 0 else {
            throw WebsiteUpdateError.message("无法创建课程更新窗口，请检查浏览器自动化权限。")
        }
        let id = window.int32Value
        managedWindowID = id
        // Explicit window id is important: window indices shift when the user opens another window.
        let selector = NSAppleScript(source: "tell application id \(Self.appleString(application.bundleID)) to return tab 1 of window id \(id)")
        guard let ownedTab = selector?.executeAndReturnError(&error), error == nil else {
            throw WebsiteUpdateError.message("未能连接课程更新窗口。")
        }
        tab = ownedTab
        var submitted = false
        var submittedAt: Date?
        var triedCredentials = false
        var waitedAfterReady = false
        for _ in 0..<90 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            guard let page = try? url(of: ownedTab) else { continue }
            guard CourseWebsite.identify(page) == site else {
                throw WebsiteUpdateError.message("网站跳转到其他登录域名，请在浏览器完成登录后再点“立即更新”。")
            }
            guard let ready = try? execute("String(document.readyState === 'complete')", in: ownedTab), ready == "true" else { continue }
            if !waitedAfterReady { waitedAfterReady = true; continue }
            if managedOwner == nil {
                let owner = "study-planner-update-" + UUID().uuidString
                _ = try execute("window.name = \(Self.literal(owner)); 'ready';", in: ownedTab)
                managedOwner = owner
            } else if try execute("String(window.name === \(Self.literal(managedOwner!)))", in: ownedTab) != "true" {
                throw WebsiteUpdateError.message("课程更新页面已变化，请重新更新。")
            }
            var login = try execute(Self.loginScript(site: site, credentials: nil, owner: managedOwner), in: ownedTab)
            if login == "login-required", !submitted, !triedCredentials {
                triedCredentials = true
                login = try execute(Self.loginScript(site: site, credentials: try credentials(), owner: managedOwner), in: ownedTab)
            }
            if login == "submitted" { submitted = true; submittedAt = Date(); continue }
            if login == "switching" { continue }
            if login == "login-required", let submittedAt, Date().timeIntervalSince(submittedAt) < 12 { continue }
            if login == "verification" || login == "login-required" {
                throw WebsiteUpdateError.loginRequired
            }
            guard login == "ready" else { continue }
            if page.path != target.path || (site == .xuecheng && page.query != target.query) {
                // Only navigate our marked tab, after login on the same allowlisted site.
                _ = try PlaybackStateReader.send(pid: pid, eventID: "setd",
                    direct: PlaybackStateReader.object("prop", container: ownedTab, property: kind == .safari ? "pURL" : "URL "),
                    parameter: ("data", .init(string: target.absoluteString)))
                waitedAfterReady = false
                continue
            }
            return try prepare(target: page)
        }
        throw WebsiteUpdateError.message("课程网页加载超时，请在浏览器检查登录状态后重试。")
    }

    static func loginScript(site: CourseWebsite, credentials: WebsiteCredentials?, owner: String? = nil) -> String {
        let credentialsJSON = credentials.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return """
        (() => {
          const hosts = \(String(data: try! JSONEncoder().encode(site.hosts), encoding: .utf8)!);
          if (location.protocol !== 'https:' || !hosts.includes(location.hostname) || (location.port && location.port !== '443')) return 'verification';
          const expectedOwner = \(owner.map(Self.literal) ?? "null");
          if (expectedOwner !== null && window.name !== expectedOwner) return 'verification';
          if (window.__studyLoginState === 'verification') return 'verification';
          const visible = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
          const inputs = [...document.querySelectorAll('input')].filter(visible);
          const passwords = inputs.filter(e => e.type === 'password');
          const controls = [...document.querySelectorAll('button, [role=button], a, span, div')].filter(e => visible(e) && e.children.length === 0);
          const text = e => e.textContent.trim();
          if (!passwords.length) {
            const switcher = controls.find(e => /^(密码登录|账号密码登录|帐号密码登录|账号登录)$/.test(text(e)));
            if (switcher) { switcher.click(); return 'switching'; }
            if (inputs.some(e => /验证码|手机号|手机号码/.test(e.placeholder || '')) || /\\/(login|signin)(\\/|$)/i.test(location.pathname)) return 'login-required';
            const login = controls.find(e => /^(登录|立即登录|去登录|登录后查看)$/.test(text(e)));
            if (login) { login.click(); return 'switching'; }
            return 'ready';
          }
          if (passwords.length !== 1) return 'verification';
          if (inputs.some(e => /验证码|captcha|one-time-code/i.test([e.placeholder,e.name,e.autocomplete].join(' '))) ||
              [...document.querySelectorAll('[class*=captcha], [id*=captcha], .tac, .geetest_panel')].some(visible)) return 'verification';
          const credential = \(credentialsJSON);
          if (!credential) return 'login-required';
          const password = passwords[0], form = password.closest('form');
          if (form?.action && new URL(form.action, location.href).origin !== location.origin) return 'verification';
          const scope = password.closest('.login-sub-wrapper, [role=dialog], .ant-modal, .el-dialog') || document;
          const usernames = [...scope.querySelectorAll('input')].filter(e => visible(e) && ['text','tel','email'].includes(e.type) &&
            /账号|帐号|手机|电话|邮箱|username|account|phone|mobile|email/i.test([e.placeholder,e.name,e.id,e.autocomplete].join(' ')));
          if (usernames.length !== 1 || [...scope.querySelectorAll('input[type=checkbox]')].some(e => visible(e) && !e.checked)) return 'verification';
          const submit = [...scope.querySelectorAll('button, [role=button], input[type=submit]')].filter(visible)
            .find(e => \(site == .yantu ? "/^(开启我的上岸之旅|登\\s*录|立即登录)$/" : "/^(登\\s*录|立即登录)$/").test((e.textContent || e.value || '').trim()) && !e.disabled);
          if (!submit) return 'verification';
          const set = (element, value) => {
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(element, value);
            element.dispatchEvent(new Event('input', {bubbles:true}));
            element.dispatchEvent(new Event('change', {bubbles:true}));
          };
          set(usernames[0], credential.username); set(password, credential.password);
          const origin = location.origin, owner = window.name;
          setTimeout(() => {
            if (location.origin !== origin || window.name !== owner || !submit.isConnected || !password.isConnected) return;
            // 学丞 uses an image for its agreement control. The enabled button class is set only after agreement.
            if (\(site == .xuecheng ? "true" : "false") && scope.querySelector('.agreement-line .check-img') && !submit.classList.contains('loginBtn-check')) {
              window.__studyLoginState = 'verification'; return;
            }
            submit.click();
          }, 250);
          return 'submitted';
        })()
        """
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
        let container = managedWindowID.map { "window id \($0)" } ?? "front window"
        let source = "tell application id \(appleString(application.bundleID)) to make new tab at end of tabs of \(container) with properties {URL:\(appleString(url.absoluteString))}"
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
