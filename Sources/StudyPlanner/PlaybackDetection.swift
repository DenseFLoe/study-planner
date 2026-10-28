import Foundation

struct SupervisedApplication: Codable, Equatable, Sendable {
    var bundleID: String
    var name: String
    var path: String

    var scripting: PlaybackScripting? {
        if ["com.apple.Safari", "com.apple.SafariTechnologyPreview"].contains(bundleID) { return .safari }
        if bundleID == "com.apple.QuickTimePlayerX" { return .quickTime }
        if ["com.apple.Music", "com.apple.TV", "com.spotify.client"].contains(bundleID) { return .playerState }
        guard let bundle = Bundle(url: URL(fileURLWithPath: path)),
              let definition = (bundle.object(forInfoDictionaryKey: "OSAScriptingDefinition") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "NSScriptingDefinition") as? String),
              let url = bundle.url(forResource: definition, withExtension: nil),
              let source = try? String(contentsOf: url, encoding: .utf8), source.contains("CrSuExJa") else { return nil }
        return .chromium
    }
}

enum PlaybackScripting: Sendable { case safari, chromium, quickTime, playerState }
enum PlaybackObservation: Equatable, Sendable {
    case playing(String), stopped(String), unavailable(String)
}

enum PlaybackAudioDetection {
    static let stoppedOutput = PlaybackObservation.stopped("该软件已暂停或停止音频输出")
    static let authorizationHelp = "请让软件有声播放，再点击“授权并检查”完成系统音频检测授权。"

    /// A known idle output is independent of capture permission. Missing or
    /// unreadable capture data alone never proves that playback has stopped.
    @MainActor static func check(
        captureAllowed: Bool, previouslyVerified: Bool,
        readOutputActivity: () throws -> [Bool?],
        readSample: () async throws -> (received: Double, active: Double)
    ) async throws -> PlaybackObservation {
        let activity = try readOutputActivity()
        if activity.allSatisfy({ $0 == false }) { return stoppedOutput }
        guard captureAllowed else { return .unavailable(authorizationHelp) }
        let sample = try await readSample()
        if sample.received > 1, sample.active >= 1 {
            return .playing("检测到该软件持续输出音频（静音视频可能无法识别）")
        }
        // Playback can be paused during the five-second sample. Re-read instead
        // of mistaking its stopped IO callbacks for an unavailable detector.
        if try readOutputActivity().allSatisfy({ $0 == false }) { return stoppedOutput }
        guard sample.received > 1 else {
            return .unavailable("未收到有效音频采样，暂时无法判断播放状态；请在软件有声播放时检查系统音频录制权限及输出设备。")
        }
        guard previouslyVerified else {
            return .unavailable("尚未验证音频权限；请让软件有声播放，再点击“授权并检查”。")
        }
        return .stopped("未检测到该软件持续输出音频（静音视频可能无法识别）")
    }
}

enum PlaybackAutomationPermission: Equatable, Sendable {
    case granted, consentRequired, denied, notRunning, failed(Int32)

    init(status: Int32) {
        switch status {
        case 0: self = .granted
        case -1744: self = .consentRequired // errAEEventWouldRequireUserConsent
        case -1743: self = .denied // errAEEventNotPermitted
        case -600: self = .notRunning // procNotFound
        default: self = .failed(status)
        }
    }

    func message(for name: String) -> String? {
        switch self {
        case .granted: return nil
        case .consentRequired:
            return "需要允许学习日程读取“\(name)”的播放状态；请点击“授权并检查”，并在系统弹窗中选择允许。"
        case .denied:
            return "未获得“\(name)”的自动化权限；请到“系统设置 → 隐私与安全性 → 自动化 → 学习日程”开启“\(name)”，再点击“授权并检查”。若没有对应项，请从打包后的学习日程.app 重试。"
        case .notRunning:
            return "“\(name)”已退出；请打开软件后再点击“授权并检查”。"
        case .failed(let status):
            return "“\(name)”的自动化权限检查失败（错误码 \(status)）；请确认软件已打开，再点击“授权并检查”。"
        }
    }
}

enum PlaybackDetection {
    static let safariJavaScriptHelp = "Safari 需要开启“开发 → 允许来自 Apple 事件的 JavaScript”。若没有“开发”菜单，请在“Safari → 设置 → 高级”中开启网页开发者功能（旧版为“在菜单栏中显示‘开发’菜单”），然后回到学习日程点击“授权并检查”。"

    static func scriptFailure(code: Int, kind: PlaybackScripting, name: String,
                              executingJavaScript: Bool = false) -> PlaybackObservation {
        // Safari reports error 8 for its separate JavaScript-from-Apple-events switch.
        // Do not display raw event error strings: they can contain page information.
        if kind == .safari, executingJavaScript, code == 8 {
            return .unavailable(safariJavaScriptHelp)
        }
        if [-1743, -1744, -600].contains(code),
           let message = PlaybackAutomationPermission(status: Int32(code)).message(for: name) {
            return .unavailable(message)
        }
        if code == -1712 { return .unavailable("“\(name)”响应超时；请稍后重试，超时不代表权限被拒绝。") }
        let help = kind == .safari && executingJavaScript ? " " + safariJavaScriptHelp : ""
        return .unavailable("暂时无法读取“\(name)”的播放状态（错误码 \(code)）。" + help)
    }

    /// Both manual authorization and background checks use this path. Background
    /// checks omit requestAutomation, so they can never show a consent prompt.
    @MainActor static func check(
        kind: PlaybackScripting?, name: String,
        requestAutomation: (() async -> PlaybackAutomationPermission)? = nil,
        readScripted: () async -> PlaybackObservation?,
        readAudio: () async -> PlaybackObservation
    ) async -> PlaybackObservation {
        if kind != nil, let requestAutomation,
           let message = await requestAutomation().message(for: name) {
            return .unavailable(message)
        }
        let scripted = await readScripted()
        if let scripted {
            switch scripted {
            case .playing, .stopped: return scripted
            case .unavailable: break
            }
        }
        // Shared WebKit audio processes cannot reliably be attributed to Safari.
        // Never hide its automation/JavaScript error behind an unrelated audio error,
        // including for bindings that previously saved audioAuthorized = true.
        if kind == .safari {
            return scripted ?? .unavailable("未能读取 Safari 的播放状态。" + safariJavaScriptHelp)
        }
        let audio = await readAudio()
        if case .unavailable(let scriptDetail) = scripted,
           case .unavailable(let audioDetail) = audio {
            return .unavailable(scriptDetail + " " + audioDetail)
        }
        return audio
    }
}
