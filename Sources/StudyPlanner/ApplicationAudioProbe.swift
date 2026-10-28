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

    static func sample(_ app: SupervisedApplication, captureAllowed: Bool = true,
                       previouslyVerified: Bool = false) async -> PlaybackObservation {
        let probe = ApplicationAudioProbe()
        defer { probe.stop() }
        do {
            let processes = try matchingProcesses(app)
            return try await PlaybackAudioDetection.check(captureAllowed: captureAllowed,
                previouslyVerified: previouslyVerified,
                readOutputActivity: {
                    // Refresh after sampling too: a player can close/recreate
                    // its audio process when it pauses or switches files.
                    try matchingProcesses(app).map(outputIsRunning)
                },
                readSample: {
                    let meter = try probe.start(processes)
                    try await Task.sleep(for: .seconds(5))
                    return meter.snapshot()
                })
        } catch is CancellationError {
            return .unavailable("检测已暂停")
        } catch {
            return .unavailable("音频检测暂不可用（错误码 \((error as NSError).code)）；请稍后重试，并检查系统音频录制权限及输出设备。")
        }
    }

    private static func matchingProcesses(_ app: SupervisedApplication) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sizeStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(sizeStatus)) }
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // HAL may shrink the process list between the size and data reads.
        objects = Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        let roots = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
            + [URL(fileURLWithPath: app.path).resolvingSymlinksInPath().path]
        return try objects.filter { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let pidStatus = AudioObjectGetPropertyData(object, &property, 0, nil, &pidSize, &pid)
            guard pidStatus == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(pidStatus)) }
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

    private static func outputIsRunning(_ process: AudioObjectID) -> Bool? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &property, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
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
