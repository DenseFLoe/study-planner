import Foundation
import StudyCore

public struct PlannerBackupEntry: Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var reason: String
    public var courseCount: Int
    public var deletedCourseID: UUID?
    public var deletedCourseName: String?
}

/// Serial, bounded local history. Every completed write is atomic and owner-readable only.
public actor PlannerBackupRepository {
    public static let maximumBytes = 64 * 1024 * 1024
    private let directory: URL?
    private let limit: Int
    private var memory: [UUID: PlannerBackup] = [:]
    public private(set) var unreadableCount = 0

    public init(inMemory: Bool = false, directory: URL? = nil, limit: Int = 20) {
        self.directory = inMemory ? nil : (directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudyPlanner/Backups"))
        self.limit = max(1, limit)
    }

    @discardableResult public func save(_ backup: PlannerBackup) throws -> PlannerBackup {
        let data = try Self.encode(backup)
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(backup.id.uuidString + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } else { memory[backup.id] = backup }
        // A clock correction or tied timestamp must not evict the recovery point
        // just written before its caller commits a business-data change.
        for entry in try entries().filter({ $0.id != backup.id }).dropFirst(limit - 1) {
            if let directory { try FileManager.default.removeItem(at: directory.appendingPathComponent(entry.id.uuidString + ".json")) }
            else { memory.removeValue(forKey: entry.id) }
        }
        return backup
    }

    public func entries() throws -> [PlannerBackupEntry] {
        let values: [PlannerBackupEntry]
        unreadableCount = 0
        if let directory {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            values = files.compactMap { url in
                do {
                    let value = try Self.read(url)
                    guard value.id == UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw SyncFailure.invalidData }
                    // Keep only list metadata; retaining every decoded planner at
                    // once multiplies memory use by the history retention limit.
                    return Self.entry(for: value)
                } catch { unreadableCount += 1; return nil }
            }
        } else { values = memory.values.map(Self.entry(for:)) }
        return values.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
    }

    private static func entry(for backup: PlannerBackup) -> PlannerBackupEntry {
        .init(id: backup.id, createdAt: backup.createdAt, reason: backup.reason, courseCount: backup.state.courses.count,
              deletedCourseID: backup.deletedCourseID, deletedCourseName: backup.state.courses.first { $0.id == backup.deletedCourseID }?.name)
    }

    public func load(_ id: UUID) throws -> PlannerBackup {
        if let directory {
            let value = try Self.read(directory.appendingPathComponent(id.uuidString + ".json"))
            guard value.id == id else { throw SyncFailure.invalidData }
            return value
        }
        guard let value = memory[id] else { throw CocoaError(.fileReadNoSuchFile) }
        return value
    }

    public nonisolated static func encode(_ backup: PlannerBackup) throws -> Data {
        _ = try backup.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(backup)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return data
    }

    public nonisolated static func read(_ url: URL) throws -> PlannerBackup {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else { throw SyncFailure.invalidData }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try readBoundedData(from: file, limit: maximumBytes)
        return try JSONDecoder().decode(PlannerBackup.self, from: data).validated()
    }

    /// Enforce the cap while reading, including when the file grows after stat.
    nonisolated static func readBoundedData(from file: FileHandle, limit: Int) throws -> Data {
        try BoundedFileData.read(from: file, limit: limit)
    }
}
