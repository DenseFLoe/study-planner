import AppKit
import ApplicationServices
import Carbon

struct SupervisedApplication: Codable, Equatable, Sendable {
    var bundleID: String
    var name: String
    var path: String

    var scripting: PlaybackScripting? {
        if bundleID == "com.apple.Safari" { return .safari }
        if bundleID == "com.apple.QuickTimePlayerX" { return .quickTime }
        if ["com.apple.Music", "com.apple.TV", "com.spotify.client"].contains(bundleID) { return .playerState }
        guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
              let definition = bundle.object(forInfoDictionaryKey: "NSScriptingDefinition") as? String,
              let url = bundle.url(forResource: definition, withExtension: nil),
              let source = try? String(contentsOf: url, encoding: .utf8), source.contains("CrSuExJa") else { return nil }
        return .chromium
    }
}

enum PlaybackScripting: Sendable { case safari, chromium, quickTime, playerState }
enum PlaybackObservation: Sendable {
    case playing(String), stopped(String), unavailable(String)
}

/// All Apple events target an already-running PID. Queries cannot launch an app,
/// activate a window, change the selected tab, or move the user between Spaces.
enum PlaybackStateReader {
    static func read(_ app: SupervisedApplication, pid: pid_t) async -> PlaybackObservation? {
        guard let kind = app.scripting else { return nil }
        return await Task.detached(priority: .utility) { read(kind, pid: pid) }.value
    }

    static func authorize(pid: pid_t) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true) == noErr
        }.value
    }

    private static func code(_ text: String) -> OSType {
        text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static func object(_ desired: String, container: NSAppleEventDescriptor = .null(),
                               property: String? = nil) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(.init(typeCode: code(desired)), forKeyword: code("want"))
        record.setDescriptor(.init(enumCode: code(property == nil ? "indx" : "prop")), forKeyword: code("form"))
        let selection = property.map { NSAppleEventDescriptor(typeCode: code($0)) }
            ?? NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, data: NSAppleEventDescriptor(enumCode: code("all ")).data)
        guard let selection else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail)) }
        record.setDescriptor(selection, forKeyword: code("seld"))
        record.setDescriptor(container, forKeyword: code("from"))
        guard let specifier = NSAppleEventDescriptor(descriptorType: typeObjectSpecifier, data: record.data) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAECoercionFail))
        }
        return specifier
    }

    private static func send(pid: pid_t, eventClass: String = "core", eventID: String = "getd",
                             direct: NSAppleEventDescriptor, parameter: (String, NSAppleEventDescriptor)? = nil) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: code(eventClass), eventID: code(eventID),
            targetDescriptor: .init(processIdentifier: pid), returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(direct, forKeyword: keyDirectObject)
        if let parameter { event.setParam(parameter.1, forKeyword: code(parameter.0)) }
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, .dontRecord], timeout: 1)
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber), number.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(number.int32Value))
        }
        return reply.paramDescriptor(forKeyword: keyDirectObject) ?? .null()
    }

    private static func read(_ kind: PlaybackScripting, pid: pid_t) -> PlaybackObservation {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else {
            return .unavailable("需要授权自动化检测；请打开软件后点击“授权并检查”。")
        }
        do {
            if kind == .playerState {
                let state = try send(pid: pid, direct: object("prop", property: "pPlS"))
                guard state.descriptorType == typeEnumerated else { return .unavailable("软件没有返回可识别的播放状态。") }
                if ["kPSP", "kPSF", "kPSR"].map(code).contains(state.enumCodeValue) { return .playing("软件报告正在播放") }
                if ["kPSp", "kPSS"].map(code).contains(state.enumCodeValue) { return .stopped("软件报告已暂停或停止") }
                return .unavailable("软件返回了未知的播放状态。")
            }
            if kind == .quickTime {
                let documents = try send(pid: pid, direct: object("docu"))
                guard documents.descriptorType == typeAEList else { return .unavailable("未能读取 QuickTime 的播放文稿列表。") }
                for index in 1..<(documents.numberOfItems + 1) {
                    guard let document = documents.atIndex(index) else { continue }
                    if try send(pid: pid, direct: object("prop", container: document, property: "play")).booleanValue {
                        return .playing("QuickTime 正在播放")
                    }
                }
                return .stopped("QuickTime 已暂停或没有播放文稿")
            }
            let windows = try send(pid: pid, direct: object("cwin"))
            guard windows.descriptorType == typeAEList else { return .unavailable("未能读取浏览器窗口列表。") }
            let deadline = Date().addingTimeInterval(8)
            var inspected = 0, failed = false, mediaFound = false
            for index in 1..<(windows.numberOfItems + 1) {
                guard Date() < deadline, let window = windows.atIndex(index) else { failed = true; break }
                let tabs = try send(pid: pid, direct: object(kind == .safari ? "bTab" : "CrTb", container: window))
                guard tabs.descriptorType == typeAEList else { failed = true; continue }
                for tabIndex in 1..<(tabs.numberOfItems + 1) {
                    guard inspected < 100, Date() < deadline, let tab = tabs.atIndex(tabIndex) else { failed = true; break }
                    inspected += 1
                    do {
                        let result: NSAppleEventDescriptor
                        if kind == .safari {
                            result = try send(pid: pid, eventClass: "sfri", eventID: "dojs", direct: .init(string: mediaScript), parameter: ("dcnm", tab))
                        } else {
                            result = try send(pid: pid, eventClass: "CrSu", eventID: "ExJa", direct: tab, parameter: ("JvSc", .init(string: mediaScript)))
                        }
                        switch result.stringValue {
                        case "playing": return .playing("浏览器中有音视频正在播放")
                        case "stopped": mediaFound = true
                        case "empty": break
                        default: failed = true
                        }
                    } catch { failed = true }
                }
            }
            if failed { return .unavailable("部分标签页无法读取；浏览器可能需要允许来自 Apple 事件的 JavaScript。") }
            return .stopped(mediaFound ? "浏览器中的音视频已暂停" : "浏览器没有正在播放的音视频")
        } catch {
            return .unavailable("暂时无法读取播放状态；请确认软件已打开且已授权。")
        }
    }

    // Returns only a state. No URLs, page titles, course names, or media content leave the browser.
    private static let mediaScript = #"""
    (() => {
      let found = false, playing = false, inaccessible = false;
      const visit = (doc) => {
        for (const media of doc.querySelectorAll('video,audio')) {
          found = true;
          if (!media.paused && !media.ended && !media.seeking && media.readyState >= 2 && media.playbackRate > 0) playing = true;
        }
        for (const frame of doc.querySelectorAll('iframe,frame')) {
          try { if (frame.contentDocument) visit(frame.contentDocument); else inaccessible = true; }
          catch (_) { inaccessible = true; }
        }
      };
      visit(document);
      return playing ? 'playing' : (inaccessible ? 'unknown' : (found ? 'stopped' : 'empty'));
    })()
    """#
}
