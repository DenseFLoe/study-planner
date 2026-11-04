import Foundation

/// The byte limit applies to actual reads, even if a file grows after a size check.
enum BoundedFileData {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try read(from: file, limit: limit)
    }

    static func read(from file: FileHandle, limit: Int) throws -> Data {
        guard limit >= 0, limit < Int.max else { throw CocoaError(.coderReadCorrupt) }
        var data = Data()
        while let part = try file.read(upToCount: min(64 * 1024, limit - data.count + 1)), !part.isEmpty {
            guard part.count <= limit - data.count else { throw CocoaError(.coderReadCorrupt) }
            data.append(part)
        }
        return data
    }
}
