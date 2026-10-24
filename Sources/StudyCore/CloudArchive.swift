import Foundation
import zlib

/// A complete portable ledger, including tombstones; timestamps belong to records, not uploads.
public struct CloudArchive: Codable, Sendable {
    public var format = 1
    public var archiveID: String
    public var device: String
    public var createdAt: Int64
    public var serverID: String?
    public var revision: Int64?
    public var records: [SyncRecord]
    public init(ledger: SyncLedger, now: Date = Date()) {
        archiveID = stablePlannerID("cloud|\(ledger.device)|\(ledger.sequence)").uuidString
        device = ledger.device; createdAt = Int64(now.timeIntervalSince1970 * 1000)
        records = ledger.records.values.sorted { $0.key < $1.key }
    }
    public func validated() throws -> CloudArchive {
        guard format == 1, UUID(uuidString: archiveID) != nil, !device.isEmpty, device.count <= 64,
              createdAt >= 0, records.count <= 200_000,
              Set(records.map(\.key)).count == records.count,
              records.contains(where: { $0.kind == "settings" && !$0.deleted }) else { throw SyncFailure.invalidData }
        var check = SyncLedger(); try check.merge(records); _ = try check.materialize()
        return self
    }
}

public struct CloudProgress: Codable, Sendable {
    public var endpoint: String
    public var serverID: String
    public var revision: Int64
    public var uploadedSequence: Int64
    public var lastSuccess: Double
    public init(endpoint: String, serverID: String, revision: Int64, uploadedSequence: Int64, lastSuccess: Double) {
        self.endpoint = endpoint; self.serverID = serverID; self.revision = revision
        self.uploadedSequence = uploadedSequence; self.lastSuccess = lastSuccess
    }
}

public enum CloudCompression {
    public static let maximumSize = 128 * 1024 * 1024
    public static let maximumCompressedSize = 32 * 1024 * 1024
    public static func gzip(_ input: Data) throws -> Data { try transform(input, encode: true) }
    public static func gunzip(_ input: Data) throws -> Data { try transform(input, encode: false) }
    private static func transform(_ input: Data, encode: Bool) throws -> Data {
        guard !input.isEmpty, input.count <= (encode ? maximumSize : maximumCompressedSize) else { throw SyncFailure.invalidData }
        var stream = z_stream()
        let initialized = encode
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initialized == Z_OK else { throw SyncFailure.invalidData }
        defer { if encode { deflateEnd(&stream) } else { inflateEnd(&stream) } }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { target in
                    stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!
                    stream.avail_out = uInt(target.count)
                    return encode ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard output.count + count <= (encode ? maximumCompressedSize : maximumSize) else { throw SyncFailure.invalidData }
                output.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw SyncFailure.invalidData }
                    return output
                }
                guard status == Z_OK, count > 0 else { throw SyncFailure.invalidData }
            }
        }
    }
}

/// Files survive process exit and failed uploads. The committed database remains the source of truth.
public enum CloudOutbox {
    public static let enabledKey = "studyPlannerCloudSyncEnabled"
    public static func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StudyPlanner/CloudOutbox", isDirectory: true)
    }
    @discardableResult public static func enqueue(_ ledger: SyncLedger, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(ledger.device)-\(ledger.sequence).json.gz")
        if !FileManager.default.fileExists(atPath: file.path) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try CloudCompression.gzip(encoder.encode(CloudArchive(ledger: ledger))).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return file
    }
    public static func files(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasSuffix(".json.gz") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
    }
}

public extension Notification.Name {
    static let plannerDidCommit = Notification.Name("StudyPlannerDidCommit")
}
