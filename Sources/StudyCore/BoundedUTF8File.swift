import Foundation

public enum BoundedTextFileError: LocalizedError {
    case tooLarge, invalidUTF8, invalidLimit
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "文件超过允许的大小。"
        case .invalidUTF8: "文件不是有效的 UTF-8 文本。"
        case .invalidLimit: "文件读取上限无效。"
        }
    }
}

public enum BoundedUTF8File {
    public static func read(_ url: URL, maximumBytes: Int) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try read(from: file, maximumBytes: maximumBytes)
    }

    static func read(from file: FileHandle, maximumBytes: Int) throws -> String {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw BoundedTextFileError.invalidLimit }
        var data = Data()
        // Probe at most one byte beyond the limit; do not trust a previous stat.
        while let part = try file.read(upToCount: min(16 * 1024, maximumBytes - data.count + 1)), !part.isEmpty {
            data.append(part)
            guard data.count <= maximumBytes else { throw BoundedTextFileError.tooLarge }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BoundedTextFileError.invalidUTF8 }
        return text
    }
}
