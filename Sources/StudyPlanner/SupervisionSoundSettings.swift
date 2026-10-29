import AppKit
import AVFoundation
import Observation
import UserNotifications

/// This Mac's audio and preference never enter PlannerState or sync archives.
@MainActor @Observable final class SupervisionSoundSettings {
    struct Selection: Codable, Equatable, Sendable {
        let filename: String
        let displayName: String
        let duration: TimeInterval
    }

    static let preferenceKey = "macSupervisionSound.v1"
    nonisolated private static let filePrefix = "studyplanner-supervision-"
    private(set) var selection: Selection?
    private(set) var importing = false
    private(set) var testing = false
    private(set) var message: String?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let soundsDirectory: URL
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var preview: NSSound?

    init(defaults: UserDefaults? = .standard, soundsDirectory: URL? = nil) {
        self.defaults = defaults
        self.soundsDirectory = soundsDirectory ?? FileManager.default.urls(for: .libraryDirectory,
            in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
        if let data = defaults?.data(forKey: Self.preferenceKey) {
            do {
                let saved = try JSONDecoder().decode(Selection.self, from: data)
                guard Self.owns(saved.filename), saved.duration > 0, saved.duration < 30 else {
                    throw SoundError.invalid
                }
                selection = saved
            } catch {
                writable = false
                message = "提示音设置读取失败，暂用系统默认声音；原设置未覆盖，请重新启动后检查。"
            }
        }
    }

    var customSoundURL: URL? {
        guard let selection else { return nil }
        let url = soundsDirectory.appendingPathComponent(selection.filename)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    var title: String {
        guard let selection else { return "系统默认提示音" }
        return selection.displayName + (customSoundURL == nil ? "（文件丢失，使用系统默认）" : "")
    }

    var notificationSound: UNNotificationSound {
        guard let url = customSoundURL else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: url.lastPathComponent))
    }

    @discardableResult
    func importSound(from source: URL) async -> Bool {
        guard writable, !importing, !testing else { return false }
        importing = true
        message = nil
        defer { importing = false }
        let destination = soundsDirectory.appendingPathComponent(Self.filePrefix + UUID().uuidString + ".caf")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let next = try await Task.detached(priority: .userInitiated) {
                try Self.convert(source: source, destination: destination)
            }.value
            let encoded = try JSONEncoder().encode(next)
            defaults?.set(encoded, forKey: Self.preferenceKey)
            stopPreview()
            let previous = selection
            selection = next
            removeOwnedFile(previous)
            message = "自定义提示音已保存，立即生效，仅保存在此 Mac。"
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            message = (error as? SoundError)?.errorDescription ?? "音频导入失败，请选择可播放的 MP3、M4A、WAV、AIFF 或 CAF 文件。原提示音保持不变。"
            return false
        }
    }

    func restoreDefault() {
        guard writable, !importing, !testing else { return }
        stopPreview()
        let previous = selection
        defaults?.removeObject(forKey: Self.preferenceKey)
        selection = nil
        removeOwnedFile(previous)
        message = "已恢复系统默认提示音。"
    }

    func playPreview() {
        stopPreview()
        guard let url = customSoundURL, let sound = NSSound(contentsOf: url, byReference: false), sound.play() else {
            message = "无法试听，请重新导入音频。"
            return
        }
        preview = sound
        message = "正在试听音频。实际通知声音可通过“发送测试通知”检查。"
    }

    func stopPreview() { preview?.stop(); preview = nil }

    /// Explicit user action; exercises the same system sound as supervision.
    func sendTestNotification() async {
        guard !testing, !importing else { return }
        testing = true
        stopPreview()
        defer { testing = false }
        do {
            let center = UNUserNotificationCenter.current()
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                message = "通知未允许，请在“系统设置 → 通知 → 学习日程”中开启通知和播放通知声音。"
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "学习监督提示音测试"
            content.body = "这是当前提示音的测试通知。"
            content.sound = notificationSound
            try await center.add(UNNotificationRequest(identifier: "supervision-sound-test", content: content, trigger: nil))
            message = settings.soundSetting == .enabled
                ? "测试通知已提交；请确认是否听到提示音。通知声音受系统音量和专注模式影响。"
                : "测试通知已提交，但系统关闭了通知声音。请在“系统设置 → 通知 → 学习日程”中开启“播放通知声音”。"
        } catch {
            message = "测试通知发送失败，请检查系统通知设置。"
        }
    }

    private func removeOwnedFile(_ selection: Selection?) {
        guard let selection, Self.owns(selection.filename) else { return }
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(selection.filename))
    }

    nonisolated private static func owns(_ filename: String) -> Bool {
        guard filename.hasPrefix(filePrefix), filename.hasSuffix(".caf") else { return false }
        let id = String(filename.dropFirst(filePrefix.count).dropLast(4))
        return UUID(uuidString: id) != nil
    }

    nonisolated private static func convert(source: URL, destination: URL) throws -> Selection {
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw SoundError.invalid }
        guard size <= 30 * 1024 * 1024 else { throw SoundError.tooLarge }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard (1...2).contains(format.channelCount), (8_000...192_000).contains(format.sampleRate),
              input.length > 0 else { throw SoundError.invalid }
        guard Double(input.length) / format.sampleRate < 30 else { throw SoundError.tooLong }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw SoundError.invalid }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Re-encode, rather than copying an arbitrary codec into a supported container.
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        var frames: AVAudioFramePosition = 0
        while frames < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, input.length - frames)))
            guard buffer.frameLength > 0 else { break }
            frames += AVAudioFramePosition(buffer.frameLength)
            guard Double(frames) / format.sampleRate < 30 else { throw SoundError.tooLong }
            try output.write(from: buffer)
        }
        guard frames > 0 else { throw SoundError.invalid }
        return Selection(filename: destination.lastPathComponent, displayName: String(source.lastPathComponent.prefix(120)),
                         duration: Double(frames) / format.sampleRate)
    }

    private enum SoundError: LocalizedError {
        case invalid, tooLong, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalid: "请选择有效的单声道或双声道音频文件。原提示音保持不变。"
            case .tooLong: "提示音必须短于 30 秒，请先剪短后重试。原提示音保持不变。"
            case .tooLarge: "音频文件不能超过 30 MB，请先压缩或剪短后重试。原提示音保持不变。"
            }
        }
    }
}
