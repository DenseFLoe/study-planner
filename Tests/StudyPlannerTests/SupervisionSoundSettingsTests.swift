import AVFoundation
import XCTest
import UserNotifications
@testable import StudyPlanner

@MainActor final class SupervisionSoundSettingsTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let sounds: URL
        let settings: SupervisionSoundSettings

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "test.studyplanner.sound." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            sounds = root.appendingPathComponent("Sounds")
            settings = SupervisionSoundSettings(defaults: defaults, soundsDirectory: sounds)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func audio(_ root: URL, name: String = "提示音.wav", duration: Double = 0.2, aac: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        let rate = 44_100.0
        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let count = AVAudioFrameCount(duration * rate)
        if count > 0 {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            buffer.frameLength = count
            for index in 0..<Int(count) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / rate) * 0.1) }
            try file.write(from: buffer)
        }
        return url
    }

    func testDefaultDoesNotWritePreferenceOrCreateFiles() throws {
        let f = try Fixture(); defer { f.clean() }
        XCTAssertNil(f.settings.selection)
        XCTAssertEqual(f.settings.notificationSound, .default)
        XCTAssertNil(f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.sounds.path))
    }

    func testImportCopiesAudioAndSurvivesMovingOriginalAndRestart() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try audio(f.root)
        let imported = await f.settings.importSound(from: source)
        XCTAssertTrue(imported, f.settings.message ?? "")
        let saved = try XCTUnwrap(f.settings.customSoundURL)
        XCTAssertEqual(saved.pathExtension, "caf")
        let converted = try AVAudioFile(forReading: saved)
        XCTAssertEqual(converted.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(converted.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(f.settings.selection?.duration ?? 0, 0.2, accuracy: 0.001)
        try FileManager.default.removeItem(at: source)
        let reopened = SupervisionSoundSettings(defaults: f.defaults, soundsDirectory: f.sounds)
        XCTAssertEqual(reopened.selection, f.settings.selection)
        XCTAssertEqual(reopened.customSoundURL, saved)
        XCTAssertNotEqual(reopened.notificationSound, .default)
    }

    func testCompressedM4AIsReencodedAsNotificationPCM() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try audio(f.root, name: "压缩音频.m4a", aac: true)
        let imported = await f.settings.importSound(from: source)
        XCTAssertTrue(imported, f.settings.message ?? "")
        let converted = try AVAudioFile(forReading: XCTUnwrap(f.settings.customSoundURL))
        XCTAssertEqual(converted.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertGreaterThan(converted.length, 0)
        XCTAssertLessThan(f.settings.selection?.duration ?? 30, 30)
    }

    func testInvalidImportKeepsPreviousSoundAndLeavesNoPartialFile() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try audio(f.root)
        let imported = await f.settings.importSound(from: source)
        XCTAssertTrue(imported)
        let previous = try XCTUnwrap(f.settings.selection)
        let preference = f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey)
        let invalid = f.root.appendingPathComponent("bad.mp3")
        try Data("not audio".utf8).write(to: invalid)
        let invalidImported = await f.settings.importSound(from: invalid)
        XCTAssertFalse(invalidImported)
        XCTAssertEqual(f.settings.selection, previous)
        XCTAssertEqual(f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey), preference)
        XCTAssertNotNil(f.settings.customSoundURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.sounds.path), [previous.filename])
    }

    func testReplaceAndResetRemoveOnlyOwnedCopies() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = try audio(f.root)
        let firstImported = await f.settings.importSound(from: first)
        XCTAssertTrue(firstImported)
        let oldCopy = try XCTUnwrap(f.settings.customSoundURL)
        let unrelated = f.sounds.appendingPathComponent("other-app.caf")
        try Data("unrelated".utf8).write(to: unrelated)
        let second = try audio(f.root, name: "second.wav")
        let secondImported = await f.settings.importSound(from: second)
        XCTAssertTrue(secondImported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let newCopy = try XCTUnwrap(f.settings.customSoundURL)
        f.settings.restoreDefault()
        XCTAssertNil(f.settings.selection)
        XCTAssertNil(f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey))
        XCTAssertEqual(f.settings.notificationSound, .default)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newCopy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testRejectsThirtySecondsButAcceptsJustUnderLimit() async throws {
        let f = try Fixture(); defer { f.clean() }
        let tooLong = try audio(f.root, duration: 30)
        let imported = await f.settings.importSound(from: tooLong)
        XCTAssertFalse(imported)
        XCTAssertTrue(f.settings.message?.contains("短于 30 秒") == true)
        XCTAssertNil(f.settings.selection)
        let valid = try audio(f.root, name: "shorter.wav", duration: 29.99)
        let validImported = await f.settings.importSound(from: valid)
        XCTAssertTrue(validImported, f.settings.message ?? "")
    }

    func testRejectsEmptyAndOversizedFiles() async throws {
        let f = try Fixture(); defer { f.clean() }
        let empty = try audio(f.root, duration: 0)
        let emptyImported = await f.settings.importSound(from: empty)
        XCTAssertFalse(emptyImported)
        let oversized = f.root.appendingPathComponent("oversized.wav")
        try Data().write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 31 * 1024 * 1024)
        try handle.close()
        let oversizedImported = await f.settings.importSound(from: oversized)
        XCTAssertFalse(oversizedImported)
        XCTAssertTrue(f.settings.message?.contains("30 MB") == true)
        XCTAssertNil(f.settings.selection)
        XCTAssertNil(f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey))
    }

    func testMissingCopyFallsBackWithoutDiscardingSavedPreference() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try audio(f.root)
        let imported = await f.settings.importSound(from: source)
        XCTAssertTrue(imported)
        try FileManager.default.removeItem(at: XCTUnwrap(f.settings.customSoundURL))
        let reopened = SupervisionSoundSettings(defaults: f.defaults, soundsDirectory: f.sounds)
        XCTAssertNotNil(reopened.selection)
        XCTAssertNil(reopened.customSoundURL)
        XCTAssertEqual(reopened.notificationSound, .default)
        XCTAssertTrue(reopened.title.contains("文件丢失"))
    }

    func testUntrustedPreferenceCannotReadOrDeleteAnUnownedFile() async throws {
        let f = try Fixture(); defer { f.clean() }
        let source = try audio(f.root)
        let invalid = SupervisionSoundSettings.Selection(filename: "../提示音.wav", displayName: "wrong", duration: 1)
        let data = try JSONEncoder().encode(invalid)
        f.defaults.set(data, forKey: SupervisionSoundSettings.preferenceKey)
        let reopened = SupervisionSoundSettings(defaults: f.defaults, soundsDirectory: f.sounds)
        XCTAssertNil(reopened.selection)
        XCTAssertEqual(reopened.notificationSound, .default)
        reopened.restoreDefault()
        let imported = await reopened.importSound(from: source)
        XCTAssertFalse(imported)
        XCTAssertEqual(f.defaults.data(forKey: SupervisionSoundSettings.preferenceKey), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
