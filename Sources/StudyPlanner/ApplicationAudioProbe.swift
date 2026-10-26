import AppKit
import CoreAudio
import Darwin

/// Samples a private, unmuted, process-specific tap for five seconds. Audio stays
/// in the callback buffers; only accumulated active/silent durations are retained.
@available(macOS 14.2, *)
@MainActor final class ApplicationAudioProbe {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?

    static func sample(_ app: SupervisedApplication, permissionRequest: Bool = false,
                       previouslyVerified: Bool = false) async -> PlaybackObservation {
        let processes = matchingProcesses(app)
        guard permissionRequest || !processes.isEmpty else {
            return .stopped("此软件当前没有音频输出进程")
        }
        let probe = ApplicationAudioProbe()
        defer { probe.stop() }
        do {
            let meter = try probe.start(processes)
            try await Task.sleep(for: .seconds(5))
            let sample = meter.snapshot()
            guard sample.received > 1 else {
                return previouslyVerified ? .stopped("该软件当前没有持续音频输出")
                    : .unavailable("未收到音频活动；请检查系统音频录制权限及输出设备。")
            }
            return sample.active >= 1
                ? .playing("检测到该软件持续输出音频（静音视频可能无法识别）")
                : .stopped("未检测到该软件持续输出音频（静音视频可能无法识别）")
        } catch is CancellationError {
            return .unavailable("检测已暂停")
        } catch {
            return .unavailable("音频检测未就绪；请在系统设置中允许学习日程录制系统音频。")
        }
    }

    private static func matchingProcesses(_ app: SupervisedApplication) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioObjectID>.size else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        let roots = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
            + [URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path]
        return objects.filter { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &pidSize, &pid) == noErr else { return false }
            if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == app.bundleID { return true }
            // Chromium/Electron helpers live inside their application's bundle.
            // Shared WebKit helpers are deliberately NOT attributed to Safari by name.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0 else { return false }
            let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
            return roots.contains { resolved.hasPrefix($0 + "/") }
        }
    }

    private func start(_ processes: [AudioObjectID]) throws -> AudioActivityMeter {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "学习日程播放活动检测"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try require(AudioHardwareCreateProcessTap(description, &tap))
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try require(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format))
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 || format.mBitsPerChannel == 64,
              format.mSampleRate > 0 else { throw AudioProbeError.unsupportedFormat }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "学习日程临时音频检测",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try require(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
        let meter = AudioActivityMeter(sampleRate: format.mSampleRate, bits: Int(format.mBitsPerChannel))
        try require(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device,
            DispatchQueue(label: "local.studyplanner.audio-meter", qos: .utility)) { _, input, _, _, _ in
                meter.consume(input)
            })
        guard let ioProc else { throw AudioProbeError.missingCallback }
        try require(AudioDeviceStart(device, ioProc))
        return meter
    }

    private func stop() {
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
    }

    private func require(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private enum AudioProbeError: Error { case unsupportedFormat, missingCallback }
}

private final class AudioActivityMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Double
    private let bits: Int
    private var received: Double = 0
    private var active: Double = 0

    init(sampleRate: Double, bits: Int) { self.sampleRate = sampleRate; self.bits = bits }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        var frames = 0
        var isActive = false
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / (bits / 8)
            guard count > 0 else { continue }
            frames = max(frames, count / max(1, Int(buffer.mNumberChannels)))
            var energy = 0.0
            if bits == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<count { let value = Double(samples[index]); energy += value * value }
            } else {
                let samples = data.assumingMemoryBound(to: Double.self)
                for index in 0..<count { let value = samples[index]; energy += value * value }
            }
            // -60 dB RMS, sustained for at least one second across the sample.
            if energy / Double(count) > 0.000001 { isActive = true }
        }
        let duration = Double(frames) / sampleRate
        lock.lock()
        received += duration
        if isActive { active += duration }
        lock.unlock()
    }

    func snapshot() -> (received: Double, active: Double) {
        lock.lock(); defer { lock.unlock() }
        return (received, active)
    }
}
