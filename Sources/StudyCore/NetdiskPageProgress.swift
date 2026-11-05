import Foundation

public enum NetdiskPaginationError: LocalizedError, Equatable {
    case invalidMetadata, changedDirectory, incomplete, repeatedPage

    public var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "目录分页信息不完整或无效，请重新读取。"
        case .changedDirectory: return "读取期间目录发生变化，请重新读取完整目录。"
        case .incomplete: return "目录分页未读完整，请重新读取。"
        case .repeatedPage: return "目录分页重复且没有新条目，请重新读取。"
        }
    }
}

/// Counts distinct entries rather than raw page lengths, which can include overlapping items.
public struct NetdiskPageProgress: Sendable {
    public struct Result: Sendable {
        public var newIDs: Set<String>
        public let isComplete: Bool
    }

    private var ids: Set<String> = []
    public private(set) var expectedTotal: Int?
    public var uniqueCount: Int { ids.count }
    public init() {}

    /// Without a reported total, an empty page is the only evidence that the listing has ended.
    /// A rejected page leaves the previous progress unchanged.
    public mutating func append(ids pageIDs: [String], total: Int?) throws -> Result {
        guard total.map({ $0 >= 0 }) ?? true,
              pageIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NetdiskPaginationError.invalidMetadata
        }
        if let total, let expectedTotal, total != expectedTotal {
            throw NetdiskPaginationError.changedDirectory
        }
        let expected = total ?? expectedTotal
        let newIDs = Set(pageIDs).subtracting(ids)
        let nextCount = ids.count + newIDs.count
        if let expected, nextCount > expected { throw NetdiskPaginationError.changedDirectory }
        if pageIDs.isEmpty, let expected, nextCount < expected { throw NetdiskPaginationError.incomplete }
        if !pageIDs.isEmpty, newIDs.isEmpty { throw NetdiskPaginationError.repeatedPage }
        ids.formUnion(newIDs)
        expectedTotal = expected
        return Result(newIDs: newIDs, isComplete: expected.map { nextCount == $0 } ?? pageIDs.isEmpty)
    }
}
