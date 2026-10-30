import Foundation
import StudyCore

/// Local, rebuildable cache for the complete compressed schedule result.
///
/// The snapshot is derived data: a missing, stale, or corrupt file is never
/// authoritative. `load()` surfaces decoding errors instead of hiding them, so
/// the main controller can simply recalculate on the next run. The controller
/// calls this class serially from the main thread, so no actor or write sequence
/// is needed here.
public final class CompressedScheduleRepository {
    /// Largest accepted cache size. A full snapshot stays far below this bound.
    static let maximumBytes = 32 * 1024 * 1024

    private let url: URL?
    private var memory: CompressedScheduleSnapshot?

    public init(inMemory: Bool = false, url: URL? = nil) {
        self.url = inMemory ? nil : (url ?? Self.defaultURL)
    }

    /// Returns `nil` only when no cache file exists. Every read or validation
    /// failure is thrown so the caller can discard the cache and recalculate.
    public func load() throws -> CompressedScheduleSnapshot? {
        guard let url else { return memory }
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return nil }
        if let size = try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.intValue > Self.maximumBytes {
            throw CocoaError(.coderReadCorrupt)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.coderReadCorrupt) }
        let value = try JSONDecoder().decode(CompressedScheduleSnapshot.self, from: data)
        guard value.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return value
    }

    public func save(_ value: CompressedScheduleSnapshot) throws {
        guard value.version == 1 else { throw CocoaError(.coderInvalidValue) }
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        memory = value
    }

    private static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("StudyPlanner/CompressedSchedule.json")
    }
}
