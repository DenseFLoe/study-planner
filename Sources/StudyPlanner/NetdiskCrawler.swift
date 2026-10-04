import Foundation
import StudyCore

/// Reads a whole share through the provider API, then digests it into courses and a duplicate report.
/// Read-only: it only ever calls the share token and share listing endpoints.
actor NetdiskCrawler {
    struct Limits: Sendable {
        var maxFolders: Int
        var maxFiles: Int
        var maxPagesPerFolder: Int
        var pageSize: Int
        var digest: NetdiskDigest.Limits
        init(maxFolders: Int = 3000, maxFiles: Int = 20000, maxPagesPerFolder: Int = 100, pageSize: Int = 200,
             digest: NetdiskDigest.Limits = .standard) {
            self.maxFolders = maxFolders; self.maxFiles = maxFiles
            self.maxPagesPerFolder = maxPagesPerFolder; self.pageSize = pageSize; self.digest = digest
        }
        static let standard = Limits()
    }

    struct Progress: Sendable, Equatable {
        var title: String
        var foldersRead: Int
        var foldersQueued: Int
        var filesSeen: Int
        var videosSeen: Int
        var unreadFolders: Int
        var detail: String
        var isFinished: Bool
    }

    struct Result: Sendable {
        var scan: NetdiskScan
        var duplicates: NetdiskDuplicateReport
        /// One entry per course candidate, already digested and ready for the import list.
        var courses: [NetdiskSnapshotBuilder.Course]
        /// Raw listing retained for diagnostics; share tokens must be stripped before exporting.
        var entries: [NetdiskEntry]
        var unassignedVideos: [NetdiskEntry] {
            let assigned = Set(scan.packages.flatMap { $0.videos.map(\.fid) })
            return entries.filter { NetdiskDigest.isVideo($0) && NetdiskDigest.isPlayable($0)
                && !assigned.contains($0.fid) }
        }
    }

    enum CrawlError: LocalizedError {
        case tooLarge(String)
        public var errorDescription: String? {
            if case .tooLarge(let detail) = self { return detail }
            return nil
        }
    }

    private let transport: NetdiskTransport
    private let limits: Limits
    private let onProgress: (@Sendable (Progress) -> Void)?
    /// True when the transport answers with the in-page `{ok, status, text}` envelope.
    private let unwrapsPageEnvelope: Bool
    /// Reads through this actor's own conformance, so page envelopes are unwrapped in one place.
    private var api: QuarkShareAPI { QuarkShareAPI(transport: self) }

    init(transport: NetdiskTransport, limits: Limits = .standard, unwrapsPageEnvelope: Bool = false,
         onProgress: (@Sendable (Progress) -> Void)? = nil) {
        self.transport = transport
        self.limits = limits
        self.onProgress = onProgress
        self.unwrapsPageEnvelope = unwrapsPageEnvelope
    }

    func crawl(link: NetdiskLink, passcode: String?, sourceURL: String,
               existingCourses: [Course], now: Date) async throws -> Result {
        var progress = Progress(title: "", foldersRead: 0, foldersQueued: 0, filesSeen: 0, videosSeen: 0,
                                unreadFolders: 0, detail: "正在读取分享信息…", isFinished: false)
        func report(_ detail: String? = nil) {
            if let detail { progress.detail = detail }
            progress.foldersQueued = max(0, progress.foldersQueued)
            onProgress?(progress)
        }
        report()

        let token = try await api.token(pwdID: link.pwdID, passcode: passcode)
        progress.title = token.title
        if token.needsPasscode { throw NetdiskAPIError.needsPasscode }
        report("已连接分享，正在读取目录…")

        var entries: [NetdiskEntry] = []
        var unread = 0
        var issues: [String] = []
        if let fragment = link.fragmentFID, !fragment.isEmpty {
            issues.append("链接指向子目录，已从该目录开始读取。")
        }
        var queue: [(fid: String, path: String, name: String)] =
            [(link.fragmentFID.flatMap { $0.isEmpty ? nil : $0 } ?? "0", "", token.title)]
        var foldersRead = 0
        var seenFIDs: Set<String> = []
        var videosSeen = 0

        while !queue.isEmpty {
            try Task.checkCancellation()
            if foldersRead >= limits.maxFolders {
                unread += queue.count
                issues.append("已达到单次读取上限（\(limits.maxFolders) 个目录），其余 \(queue.count) 个目录未读取。")
                queue.removeAll()
                break
            }
            let next = queue.removeFirst()
            foldersRead += 1
            var page = 1
            var expected = 0
            var seen = 0
            var pagesInFolder = 0
            while true {
                try Task.checkCancellation()
                if pagesInFolder >= limits.maxPagesPerFolder {
                    issues.append("目录「\(next.name)」分页过多，未读完。")
                    break
                }
                let listing = try await api.list(pwdID: link.pwdID, stoken: token.stoken,
                                                 directoryFID: next.fid, page: page, size: limits.pageSize,
                                                 passcode: passcode)
                pagesInFolder += 1
                expected = listing.total
                seen += listing.items.count
                for item in listing.items {
                    // A moving share can repeat an item on adjacent pages. Keep one copy and
                    // still count the provider's raw page length when deciding where to stop.
                    guard seenFIDs.insert(item.fid).inserted else { continue }
                    let isDirectory = item.dir == true
                    let entry = Self.entry(item, parentPath: next.path)
                    entries.append(entry)
                    if NetdiskDigest.isVideo(entry) { videosSeen += 1 }
                    if isDirectory {
                        queue.append((item.fid, entry.relativePath, item.fileName))
                    }
                }
                progress.foldersRead = foldersRead
                progress.foldersQueued = queue.count
                progress.filesSeen = entries.count
                progress.videosSeen = videosSeen
                progress.unreadFolders = unread
                report(foldersRead == 1 ? "正在读取「\(next.name)」…" : "已读取 \(foldersRead) 个目录…")
                if entries.count > limits.maxFiles {
                    throw CrawlError.tooLarge("这个分享包含超过 \(limits.maxFiles) 个文件，单次导入太大。请改用子目录链接。")
                }
                if !listing.hasMore || seen >= listing.total { break }
                page += 1
            }
            if expected > seen { unread += 1 }
        }

        report("目录读取完成，正在识别课程…")
        let outcome = NetdiskDigest.digest(entries: entries, rootTitle: token.title, pwdID: link.pwdID,
                                           unreadFolders: unread, issues: issues, limits: limits.digest)
        let scan = NetdiskScan(pwdID: link.pwdID, passcodeProtected: token.needsPasscode, title: token.title,
                               sourceURL: sourceURL.isEmpty ? "https://pan.quark.cn/s/" + link.pwdID : sourceURL,
                               fetchedAt: now, root: outcome.root, packages: outcome.packages,
                               totalVideoCount: outcome.totalVideoCount, totalBytes: outcome.totalBytes,
                               totalSeconds: outcome.totalSeconds, unreadFolders: outcome.unreadFolders,
                               issues: outcome.issues)
        report("课程识别完成，正在检查重复…")
        let duplicates = NetdiskDedup.scan(packages: outcome.packages, courses: existingCourses)
        // Keep the same natural folder order the user sees on the share page.
        let ordered = outcome.packages.sorted {
            return NetdiskTitles.naturalCompare($0.path, $1.path) == .orderedAscending
        }
        let courses = ordered.compactMap {
            NetdiskSnapshotBuilder.build(package: NetdiskDedup.removingSafeCopies(from: $0, report: duplicates),
                                         scan: scan)
        }
        var finished = progress
        finished.isFinished = true
        finished.detail = "读取完成：\(outcome.packages.count) 门课程，\(outcome.totalVideoCount) 个视频。"
        onProgress?(finished)
        return Result(scan: scan, duplicates: duplicates, courses: courses, entries: entries)
    }

    /// Maps one provider item onto the shared entry type.
    static func entry(_ item: QuarkShareAPI.Item, parentPath: String) -> NetdiskEntry {
        NetdiskEntry(fid: item.fid, shareToken: item.shareFidToken ?? "", name: item.fileName,
                     isDirectory: item.dir == true, fileType: item.fileType ?? 0, category: item.category ?? 0,
                     formatType: item.formatType ?? "", size: max(0, item.size ?? 0),
                     durationSeconds: item.duration, width: item.videoWidth, height: item.videoHeight,
                     updatedAt: item.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) },
                     childCount: item.includeItems, riskType: item.riskType ?? 0,
                     banned: item.ban ?? false, badContent: item.badContent ?? false,
                     status: item.status ?? 1, parentPath: parentPath)
    }
}

extension NetdiskCrawler: NetdiskTransport {
    nonisolated func get(path: String, query: [String: String]) async throws -> Data {
        try await call(path: path, query: query, body: nil)
    }
    nonisolated func post(path: String, query: [String: String], body: [String: NetdiskJSON]) async throws -> Data {
        try await call(path: path, query: query, body: body)
    }
    private func call(path: String, query: [String: String], body: [String: NetdiskJSON]?) async throws -> Data {
        let data: Data
        if let body {
            data = try await transport.post(path: path, query: query, body: body)
        } else {
            data = try await transport.get(path: path, query: query)
        }
        return unwrapsPageEnvelope ? try QuarkShareAPI.payload(fromPage: data) : data
    }
}
