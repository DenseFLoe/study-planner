import Foundation

/// One entry of a netdisk share listing: a folder or a file.
public struct NetdiskEntry: Codable, Equatable, Sendable {
    public var fid: String
    public var shareToken: String
    public var name: String
    public var isDirectory: Bool
    /// Provider file kind; quark uses 0 for folders and 1 for files.
    public var fileType: Int
    /// Provider content category; quark uses 1 for video, 4 for pdf, and so on.
    public var category: Int
    public var formatType: String
    public var size: Int64
    /// Seconds reported by the provider, when it reports one at all.
    public var durationSeconds: Double?
    public var width: Int?
    public var height: Int?
    public var updatedAt: Date?
    public var childCount: Int?
    public var riskType: Int
    public var banned: Bool
    public var badContent: Bool
    public var status: Int
    /// Path of the *containing* folder relative to the share root, without a leading slash.
    public var parentPath: String
    public init(fid: String, shareToken: String, name: String, isDirectory: Bool, fileType: Int,
                category: Int, formatType: String, size: Int64, durationSeconds: Double?,
                width: Int?, height: Int?, updatedAt: Date?, childCount: Int?, riskType: Int,
                banned: Bool, badContent: Bool, status: Int, parentPath: String) {
        self.fid = fid; self.shareToken = shareToken; self.name = name; self.isDirectory = isDirectory
        self.fileType = fileType; self.category = category; self.formatType = formatType; self.size = size
        self.durationSeconds = durationSeconds; self.width = width; self.height = height
        self.updatedAt = updatedAt; self.childCount = childCount; self.riskType = riskType
        self.banned = banned; self.badContent = badContent; self.status = status
        self.parentPath = parentPath
    }
    public var relativePath: String { parentPath.isEmpty ? name : parentPath + "/" + name }
}

/// A folder subtree as returned by the listing, used for the browser and for grouping.
public struct NetdiskDirectory: Codable, Equatable, Sendable {
    public var fid: String
    public var shareToken: String
    public var name: String
    public var path: String
    public var depth: Int
    public var fileCount: Int
    public var folderCount: Int
    public var videoCount: Int
    public var documentCount: Int
    public var otherCount: Int
    public var totalBytes: Int64
    public var totalSeconds: Double
    public var children: [NetdiskDirectory]
    public init(fid: String, shareToken: String, name: String, path: String, depth: Int,
                fileCount: Int, folderCount: Int, videoCount: Int, documentCount: Int, otherCount: Int,
                totalBytes: Int64, totalSeconds: Double, children: [NetdiskDirectory]) {
        self.fid = fid; self.shareToken = shareToken; self.name = name; self.path = path; self.depth = depth
        self.fileCount = fileCount; self.folderCount = folderCount; self.videoCount = videoCount
        self.documentCount = documentCount; self.otherCount = otherCount
        self.totalBytes = totalBytes; self.totalSeconds = totalSeconds; self.children = children
    }
    public var itemCount: Int { fileCount + folderCount }
    /// Flattened depth-first list, including this folder.
    public var flattened: [NetdiskDirectory] { [self] + children.flatMap(\.flattened) }
}

/// Why a subtree is (or is not) treated as a course.
public struct NetdiskCourseSignal: Codable, Equatable, Sendable {
    public var videoRatio: Double
    public var nameScore: Double
    public var sequenceScore: Double
    public var sizeScore: Double
    public var score: Double
    public var notes: [String]
    public init(videoRatio: Double, nameScore: Double, sequenceScore: Double, sizeScore: Double,
                score: Double, notes: [String]) {
        self.videoRatio = videoRatio; self.nameScore = nameScore; self.sequenceScore = sequenceScore
        self.sizeScore = sizeScore; self.score = score; self.notes = notes
    }
}

/// A subtree the crawler proposes importing as one course.
public struct NetdiskPackage: Codable, Equatable, Identifiable, Sendable {
    public var packageID: String
    public var name: String
    public var fid: String
    public var shareToken: String
    public var path: String
    public var depth: Int
    public var videos: [NetdiskEntry]
    public var documentCount: Int
    public var otherCount: Int
    public var totalBytes: Int64
    public var totalSeconds: Double
    /// Videos the provider reports no duration for; those are estimated from the rest of the course.
    public var unknownDurations: Int
    public var signal: NetdiskCourseSignal
    /// Height of the shortest dimension, used to compare quality between duplicate copies.
    public var minHeight: Int
    /// Folders inside this subtree that were not read because a limit was reached.
    public var unreadFolders: Int
    public init(packageID: String, name: String, fid: String, shareToken: String, path: String, depth: Int,
                videos: [NetdiskEntry], documentCount: Int, otherCount: Int, totalBytes: Int64,
                totalSeconds: Double, unknownDurations: Int, signal: NetdiskCourseSignal,
                minHeight: Int, unreadFolders: Int) {
        self.packageID = packageID; self.name = name; self.fid = fid; self.shareToken = shareToken
        self.path = path; self.depth = depth; self.videos = videos; self.documentCount = documentCount
        self.otherCount = otherCount; self.totalBytes = totalBytes; self.totalSeconds = totalSeconds
        self.unknownDurations = unknownDurations; self.signal = signal; self.minHeight = minHeight
        self.unreadFolders = unreadFolders
    }
    public var id: String { packageID }
    public var videoCount: Int { videos.count }
    public var knownDurationVideos: Int { videos.filter { $0.durationSeconds != nil }.count }
}

/// A share the crawler read, however it was reached.
public struct NetdiskScan: Codable, Equatable, Sendable {
    public var pwdID: String
    public var passcodeProtected: Bool
    public var title: String
    public var sourceURL: String
    public var fetchedAt: Date
    public var root: NetdiskDirectory
    public var packages: [NetdiskPackage]
    public var totalVideoCount: Int
    public var totalBytes: Int64
    public var totalSeconds: Double
    /// Folders skipped because a crawl limit was reached.
    public var unreadFolders: Int
    public var issues: [String]
    public init(pwdID: String, passcodeProtected: Bool, title: String, sourceURL: String, fetchedAt: Date,
                root: NetdiskDirectory, packages: [NetdiskPackage], totalVideoCount: Int,
                totalBytes: Int64, totalSeconds: Double, unreadFolders: Int, issues: [String]) {
        self.pwdID = pwdID; self.passcodeProtected = passcodeProtected; self.title = title
        self.sourceURL = sourceURL; self.fetchedAt = fetchedAt; self.root = root
        self.packages = packages; self.totalVideoCount = totalVideoCount; self.totalBytes = totalBytes
        self.totalSeconds = totalSeconds; self.unreadFolders = unreadFolders; self.issues = issues
    }
    public var displayName: String { title.isEmpty ? pwdID : title }
}

/// A parsed share link: never rewrites the link, only reads the identifiers out of it.
public struct NetdiskLink: Equatable, Sendable {
    public var pwdID: String
    /// Folder the link points at, from the `#/list/share/<fid>` fragment when present.
    public var fragmentFID: String?
    public var inAppPasscode: String?
    public init(pwdID: String, fragmentFID: String?, inAppPasscode: String?) {
        self.pwdID = pwdID; self.fragmentFID = fragmentFID; self.inAppPasscode = inAppPasscode
    }

    public static func parse(_ text: String) -> NetdiskLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let forbidden = CharacterSet(charactersIn: "\"'<>\\`{}|^")
        guard trimmed.rangeOfCharacter(from: forbidden) == nil,
              !trimmed.contains(".."),
              !trimmed.lowercased().hasPrefix("http://") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "pan.quark.cn" || host == "www.quark.cn" || host == "quark.cn" else { return nil }
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var pwdID: String?
        if let index = segments.firstIndex(of: "s"), segments.indices.contains(index + 1) {
            pwdID = sanitized(segments[index + 1])
        }
        guard let id = pwdID, !id.isEmpty else { return nil }
        return NetdiskLink(pwdID: id, fragmentFID: fragmentFID(from: url), inAppPasscode: queryPasscode(url))
    }

    /// Only hex-ish identifiers are accepted, so a pasted sentence never becomes a request.
    private static func sanitized(_ value: String) -> String? {
        let allowed = value.filter { $0.isLetter || $0.isNumber }
        guard allowed == value, (4...64).contains(value.count) else { return nil }
        return value
    }
    private static func fragmentFID(from url: URL) -> String? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else { return nil }
        let parts = fragment.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let index = parts.firstIndex(of: "share"), parts.indices.contains(index + 1) else { return nil }
        return sanitized(parts[index + 1])
    }
    private static func queryPasscode(_ url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first { $0.name.lowercased() == "pwd" || $0.name.lowercased() == "passcode" }?.value
    }
}
