import Foundation

/// Turns a raw netdisk listing into a folder tree and the course packages worth importing.
public enum NetdiskDigest {
    /// Largest share this app will read in one go, so a link to a whole drive cannot run away.
    public struct Limits: Equatable, Sendable {
        public var maxFolders: Int
        public var maxFiles: Int
        public var minVideosPerCourse: Int
        public var autoSelectScore: Double
        public init(maxFolders: Int = 60, maxFiles: Int = 2000, minVideosPerCourse: Int = 3,
                    autoSelectScore: Double = 0.62) {
            self.maxFolders = maxFolders; self.maxFiles = maxFiles
            self.minVideosPerCourse = minVideosPerCourse; self.autoSelectScore = autoSelectScore
        }
        public static let standard = Limits()
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "mkv", "avi", "flv", "mov", "wmv", "ts", "m4v", "rmvb", "rm", "webm", "mpg", "mpeg",
        "f4v", "3gp", "vob", "m2ts", "mts", "asf", "ogv", "m3u8", "mpd"
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md", "epub", "mobi", "caj",
        "djvu", "rtf", "csv", "pages", "numbers", "key", "wps", "et", "dps"
    ]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff"]

    public enum Kind: String, Codable, Sendable {
        case video, document, archive, image, other
    }

    /// Providers disagree on how they mark a video, so every signal is checked.
    public static func kind(of entry: NetdiskEntry) -> Kind {
        let format = entry.formatType.lowercased()
        let ext = `extension`(entry.name)
        if format.hasPrefix("video/") || videoExtensions.contains(ext) || entry.category == 1 || entry.category == 9 {
            return .video
        }
        if documentExtensions.contains(ext) || entry.category == 4 || entry.category == 3 {
            return .document
        }
        if archiveExtensions.contains(ext) || entry.category == 5 { return .archive }
        if imageExtensions.contains(ext) || entry.category == 2 { return .image }
        if format.hasPrefix("text/") || format.hasPrefix("application/pdf") { return .document }
        if format.hasPrefix("image/") { return .image }
        return .other
    }
    public static func `extension`(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot < name.index(before: name.endIndex) else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
    public static func isVideo(_ entry: NetdiskEntry) -> Bool { !entry.isDirectory && kind(of: entry) == .video }
    /// Files the provider flags as unrunnable or infringing are excluded from courses.
    public static func isPlayable(_ entry: NetdiskEntry) -> Bool {
        entry.status == 1 && !entry.banned && !entry.badContent && entry.riskType == 0
    }
    public static func duration(_ entry: NetdiskEntry) -> Double? {
        guard let value = entry.durationSeconds, value.isFinite, value >= 1, value <= 36_000 else { return nil }
        return value
    }
    private static func resolution(_ entry: NetdiskEntry) -> Int {
        let pixels = min(entry.width ?? 0, entry.height ?? 0)
        if pixels > 0 { return pixels }
        return NetdiskTitles.resolutionRank(entry.name)
    }

    /// Natural order for the lessons of one course: folders first, then file names.
    /// A name such as `7.1` must stay before `7.4`; mixing a separate episode score into
    /// this comparison can make a large sort inconsistent when formats vary within a folder.
    public static func lessonComparator() -> (NetdiskEntry, NetdiskEntry) -> Bool {
        lessonComparator(episodes: [:])
    }
    private static func lessonComparator(episodes: [String: Int]) -> (NetdiskEntry, NetdiskEntry) -> Bool {
        _ = episodes
        return { lhs, rhs in
            let left = lhs.parentPath, right = rhs.parentPath
            if left != right {
                let compared = NetdiskTitles.naturalCompare(left, right)
                if compared != .orderedSame { return compared == .orderedAscending }
            }
            let compared = NetdiskTitles.naturalCompare(lhs.name, rhs.name)
            if compared != .orderedSame { return compared == .orderedAscending }
            return lhs.fid < rhs.fid
        }
    }

    private struct Node {
        var entry: NetdiskEntry?
        var path: String
        var name: String
        var fid: String
        var shareToken: String
        var depth: Int
        var children: [String] = []
        var ownVideos: [NetdiskEntry] = []
        /// Files sitting directly in this folder, used to tell a container from a course.
        var ownDocumentCount = 0
        var ownOtherCount = 0
        var documentCount = 0
        var otherCount = 0
    }

    public struct Outcome: Sendable {
        public var root: NetdiskDirectory
        public var packages: [NetdiskPackage]
        public var totalVideoCount: Int
        public var totalBytes: Int64
        public var totalSeconds: Double
        public var unreadFolders: Int
        public var issues: [String]
    }

    /// Builds the tree and picks course packages. Pure: the same listing always digests the same way.
    public static func digest(entries: [NetdiskEntry], rootTitle: String, pwdID: String,
                              unreadFolders: Int = 0, issues: [String] = [],
                              limits: Limits = .standard) -> Outcome {
        var nodes: [String: Node] = [:]
        var order: [String] = []
        func node(path: String) -> Node {
            if let existing = nodes[path] { return existing }
            let name = path.isEmpty ? (rootTitle.isEmpty ? pwdID : rootTitle) : (path.split(separator: "/").last.map(String.init) ?? path)
            let created = Node(entry: nil, path: path, name: name, fid: "", shareToken: "",
                               depth: path.isEmpty ? 0 : path.split(separator: "/").count)
            nodes[path] = created
            order.append(path)
            return created
        }
        _ = node(path: "")
        for entry in entries {
            let path = entry.relativePath
            var child = node(path: path)
            child.entry = entry
            child.name = entry.name
            child.fid = entry.fid
            child.shareToken = entry.shareToken
            var parent = node(path: entry.parentPath)
            if !parent.children.contains(path) { parent.children.append(path) }
            nodes[entry.parentPath] = parent
            nodes[path] = child
        }

        // Cumulative video bytes/seconds per subtree, computed bottom-up over a depth-sorted list.
        let pathsByDepth = order.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? NetdiskTitles.naturalCompare($0, $1) == .orderedAscending : a < b
        }

        for entry in entries where !entry.isDirectory {
            let path = entry.relativePath
            switch kind(of: entry) {
            case .video:
                if isPlayable(entry) {
                    nodes[entry.parentPath]?.ownVideos.append(entry)
                } else {
                    nodes[entry.parentPath]?.ownOtherCount += 1
                    nodes[entry.parentPath]?.otherCount += 1
                }
            case .document:
                nodes[entry.parentPath]?.ownDocumentCount += 1
                nodes[entry.parentPath]?.documentCount += 1
            default:
                nodes[entry.parentPath]?.ownOtherCount += 1
                nodes[entry.parentPath]?.otherCount += 1
            }
            nodes[path] = nodes[path] ?? Node(entry: entry, path: path, name: entry.name, fid: entry.fid,
                                             shareToken: entry.shareToken,
                                             depth: path.split(separator: "/").count)
        }
        var subtreeVideos: [String: [NetdiskEntry]] = [:]
        var subtreeDocuments: [String: Int] = [:]
        var subtreeOthers: [String: Int] = [:]
        for path in pathsByDepth.reversed() {
            guard let current = nodes[path] else { continue }
            var videos = current.ownVideos
            var documents = current.documentCount
            var others = current.otherCount
            for childPath in current.children {
                videos += subtreeVideos[childPath] ?? []
                documents += subtreeDocuments[childPath] ?? 0
                others += subtreeOthers[childPath] ?? 0
            }
            subtreeVideos[path] = videos; subtreeDocuments[path] = documents; subtreeOthers[path] = others
        }
        var episodes: [String: Int] = [:]
        for video in subtreeVideos[""] ?? [] { episodes[video.fid] = NetdiskTitles.episode(in: video.name) ?? 0 }

        func directory(_ path: String) -> NetdiskDirectory {
            let current = nodes[path]
            let videos = subtreeVideos[path] ?? []
            let children = (current?.children ?? []).sorted {
                NetdiskTitles.naturalCompare($0, $1) == .orderedAscending
            }
            return NetdiskDirectory(
                fid: current?.fid ?? "", shareToken: current?.shareToken ?? "",
                name: current?.name ?? path, path: path, depth: current?.depth ?? 0,
                fileCount: (current?.ownVideos.count ?? 0) + (current?.ownDocumentCount ?? 0) + (current?.ownOtherCount ?? 0),
                folderCount: (current?.children.count ?? 0),
                videoCount: videos.count,
                documentCount: subtreeDocuments[path] ?? 0,
                otherCount: subtreeOthers[path] ?? 0,
                totalBytes: videos.reduce(0) { $0 + max(0, $1.size) },
                totalSeconds: videos.reduce(0) { $0 + (duration($1) ?? 0) },
                children: children.map(directory))
        }

        // Course candidates: every folder holding videos is scored, then the best ancestor keeps them.
        var scored: [(path: String, score: Double, signal: NetdiskCourseSignal)] = []
        for path in order {
            guard let current = nodes[path] else { continue }
            let videos = subtreeVideos[path] ?? []
            guard !videos.isEmpty else { continue }
            // The share root becomes a course only when lessons sit directly in it, which is exactly
            // what a share link into a chapter folder looks like. A root that merely wraps subfolders
            // (like the real 考研 share) stays a container for its stage courses.
            if path.isEmpty, current.ownVideos.isEmpty,
               current.children.filter({ isChapterName(nodes[$0]?.name ?? "") }).count < 2 { continue }
            let signal = signal(for: current, videos: videos, documents: subtreeDocuments[path] ?? 0,
                                others: subtreeOthers[path] ?? 0, episodes: episodes, limits: limits)
            scored.append((path, signal.score, signal))
        }
        // Some shares put each lecture in its own consecutively named folder. Merge those
        // siblings into one course while leaving a larger sibling (for example 扫码视频) separate.
        var seriesGroups: [(parent: String, stem: String, children: [String], videos: [NetdiskEntry])] = []
        for path in order {
            guard let current = nodes[path], current.ownVideos.isEmpty else { continue }
            var byStem: [String: [String]] = [:]
            for child in current.children {
                guard let name = nodes[child]?.name,
                      let stem = seriesStem(name),
                      let videos = subtreeVideos[child], (1...2).contains(videos.count) else { continue }
                byStem[stem, default: []].append(child)
            }
            for (stem, children) in byStem where children.count >= 3 {
                seriesGroups.append((path, stem, children, children.flatMap { subtreeVideos[$0] ?? [] }))
            }
        }
        var wrappers: Set<String> = []
        // A folder whose direct children are the stages of a study plan — 抢跑, 基础, 强化, 冲刺,
        // 真题 — is a container too, even though it holds every video of every stage. Chapters of one
        // recorded course (`第1章`, `01.极限`) do not look like that and keep their course.
        for path in order where !path.isEmpty {
            guard let current = nodes[path], current.ownVideos.isEmpty,
                  current.ownDocumentCount == 0, current.otherCount == 0 else { continue }
            let stageChildren = current.children.filter { child in
                guard let name = nodes[child]?.name.lowercased() else { return false }
                guard !isChapterName(name) else { return false }
                guard stageKeywords.contains(where: { name.contains($0) }) else { return false }
                return scored.contains { $0.path == child && $0.score >= 0.6 }
            }
            if stageChildren.count >= 2 { wrappers.insert(path) }
        }
        for path in order where !path.isEmpty {
            guard let current = nodes[path], current.ownVideos.isEmpty,
                  materialKeywords.contains(where: { current.name.contains($0) }) else { continue }
            if current.children.filter({ !(subtreeVideos[$0] ?? []).isEmpty }).count >= 2 {
                wrappers.insert(path)
            }
        }
        if !wrappers.isEmpty { scored.removeAll { wrappers.contains($0.path) } }
        // Chapter folders are sections of their parent course. Their names and file counts can
        // score highly, but splitting them would turn one course into dozens of plans.
        var chapterSubtrees: [String] = []
        for path in order {
            guard let current = nodes[path], !wrappers.contains(path) else { continue }
            let chapters = current.children.filter { isChapterName(nodes[$0]?.name ?? "") }
            if chapters.count >= 2 { chapterSubtrees.append(contentsOf: chapters) }
        }
        scored.removeAll { candidate in
            chapterSubtrees.contains { chapter in
                candidate.path == chapter || candidate.path.hasPrefix(chapter + "/")
            }
        }
        scored.removeAll { candidate in
            seriesGroups.contains { group in
                candidate.path == group.parent
                    || (!candidate.path.isEmpty && group.parent.hasPrefix(candidate.path + "/"))
                    || group.children.contains { child in
                        candidate.path == child || candidate.path.hasPrefix(child + "/")
                    }
            }
        }
        // A root with its own videos is a course unless it also contains at least two strong course
        // folders — then those folders are the courses and the root's loose videos stay listed.
        if let rootNode = nodes[""], !rootNode.ownVideos.isEmpty,
           scored.filter({ !$0.path.isEmpty && $0.score >= 0.6 }).count >= 2 {
            scored.removeAll { $0.path.isEmpty }
        }
        // Deeper, more specific folders win a tie: a folder and its only child must not both be courses.
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.path.count > $1.path.count
        }
        var chosen: [String] = []
        for candidate in scored {
            let contained = chosen.contains { selected in
                candidate.path == selected
                    || candidate.path.isEmpty || selected.isEmpty
                    || candidate.path.hasPrefix(selected + "/")
                    || selected.hasPrefix(candidate.path + "/")
            }
            if !contained { chosen.append(candidate.path) }
        }
        // A folder that only exists to hold one course is not itself a course worth naming.
        var packages: [NetdiskPackage] = []
        for path in chosen {
            guard let current = nodes[path], let signal = scored.first(where: { $0.path == path })?.signal else { continue }
            let videos = (subtreeVideos[path] ?? []).sorted(by: lessonComparator(episodes: episodes))
            let childFolders = current.children.count
            let display = NetdiskTitles.displayName(current.name)
            var notes = signal.notes
            if childFolders == 0, (subtreeVideos[path]?.count ?? 0) > 0 { notes.append("课节视频直接放在这一层") }
            packages.append(NetdiskPackage(
                packageID: "quark:" + pwdID + ":" + (current.fid.isEmpty ? (path.isEmpty ? "root" : path) : current.fid),
                name: display.isEmpty ? current.name : display,
                fid: current.fid, shareToken: current.shareToken, path: path, depth: current.depth,
                videos: videos,
                documentCount: subtreeDocuments[path] ?? 0, otherCount: subtreeOthers[path] ?? 0,
                totalBytes: videos.reduce(0) { $0 + max(0, $1.size) },
                totalSeconds: videos.reduce(0) { $0 + (duration($1) ?? 0) },
                unknownDurations: videos.filter { duration($0) == nil }.count,
                signal: NetdiskCourseSignal(videoRatio: signal.videoRatio, nameScore: signal.nameScore,
                                           sequenceScore: signal.sequenceScore, sizeScore: signal.sizeScore,
                                           score: signal.score, notes: notes),
                minHeight: videos.map(resolution).min() ?? 0,
                unreadFolders: 0))
        }
        for group in seriesGroups {
            guard let current = nodes[group.parent] else { continue }
            let videos = group.videos.sorted(by: lessonComparator(episodes: episodes))
            let signal = signal(for: current, videos: videos, documents: 0, others: 0,
                                episodes: episodes, limits: limits)
            packages.append(NetdiskPackage(
                packageID: "quark:" + pwdID + ":" + current.fid + ":series:" + group.stem,
                name: current.name, fid: current.fid, shareToken: current.shareToken,
                path: group.parent, depth: current.depth, videos: videos,
                documentCount: 0, otherCount: 0,
                totalBytes: videos.reduce(0) { $0 + max(0, $1.size) },
                totalSeconds: videos.reduce(0) { $0 + (duration($1) ?? 0) },
                unknownDurations: videos.filter { duration($0) == nil }.count,
                signal: NetdiskCourseSignal(videoRatio: signal.videoRatio, nameScore: signal.nameScore,
                                           sequenceScore: signal.sequenceScore, sizeScore: signal.sizeScore,
                                           score: signal.score,
                                           notes: signal.notes + ["已合并 \(group.children.count) 个连续编号的课节目录"]),
                minHeight: videos.map(resolution).min() ?? 0,
                unreadFolders: 0))
        }
        packages.sort {
            let compared = NetdiskTitles.naturalCompare($0.path, $1.path)
            return compared == .orderedSame ? $0.packageID < $1.packageID : compared == .orderedAscending
        }
        let root = directory("")
        let allVideos = subtreeVideos[""] ?? []
        return Outcome(root: root, packages: packages, totalVideoCount: allVideos.count,
                       totalBytes: allVideos.reduce(0) { $0 + max(0, $1.size) },
                       totalSeconds: allVideos.reduce(0) { $0 + (duration($1) ?? 0) },
                       unreadFolders: unreadFolders, issues: issues)
    }

    private static let courseKeywords = ["课程", "视频", "课", "讲", "精讲", "强化", "基础", "冲刺", "真题",
                                         "习题", "刷题", "直播", "回放", "伴学", "集训", "点睛", "押题",
                                         "导学", "串讲", "考点", "题型", "一轮", "二轮", "三轮", "网课",
                                         "教程", "lecture", "lesson", "course", "video"]
    private static let materialKeywords = ["资料", "讲义", "课件", "笔记", "书籍", "电子书", "答案", "解析",
                                           "试卷", "真题pdf", "文档", "扫盲", "介绍", "说明"]
    /// Folder names that mark a stage of a study plan rather than a chapter of one course.
    private static let stageKeywords = ["抢跑", "预备", "入门", "基础", "核心", "强化", "精讲", "定制",
                                        "题型", "通法", "集训", "寒假", "暑假", "春季", "秋季", "冲刺",
                                        "真题", "阶段", "模考", "押题", "伴学", "刷题", "选学"]
    private static func isChapterName(_ name: String) -> Bool {
        let value = name.lowercased()
        return value.contains("章节") || (value.contains("第") && value.contains("章"))
            || value.contains("chapter")
    }
    private static func seriesStem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.reversed().prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let stem = String(trimmed.dropLast(digits.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ._-、（）()"))
        return stem.count >= 2 ? stem : nil
    }

    /// The four signals behind "is this folder a course", each 0 ... 1.
    private static func signal(for node: Node, videos: [NetdiskEntry], documents: Int, others: Int,
                               episodes: [String: Int], limits: Limits) -> NetdiskCourseSignal {
        let content = videos.count + documents + others
        let videoRatio = content > 0 ? Double(videos.count) / Double(content) : 0
        let name = node.name.lowercased()
        var nameScore = 0.0
        var notes: [String] = []
        if courseKeywords.contains(where: { name.contains($0) }) { nameScore += 0.55 }
        if materialKeywords.contains(where: { name.contains($0) }) { nameScore -= 0.35; notes.append("目录名像资料/讲义") }
        if NetdiskTitles.episode(in: node.name) != nil { nameScore += 0.2 }
        nameScore = min(1, max(0, nameScore))
        let sequence = sequenceScore(videos: videos, episodes: episodes)
        let known = videos.compactMap { duration($0) }
        let seconds = known.isEmpty ? Double(videos.count) * 300 : known.reduce(0, +)
        let volumeScore = min(1, Double(videos.count) / Double(max(1, limits.minVideosPerCourse)) * 0.5
                                + min(1, seconds / 3600) * 0.5)
        var score = videoRatio * 0.40 + sequence * 0.20 + nameScore * 0.20 + volumeScore * 0.20
        if documents > videos.count { score = min(score, 0.5); notes.append("文档比视频还多") }
        if content > 0, videos.count < limits.minVideosPerCourse {
            score = min(score, 0.55)
            notes.append("视频少于 \(limits.minVideosPerCourse) 个")
        }
        return NetdiskCourseSignal(videoRatio: videoRatio, nameScore: nameScore, sequenceScore: sequence,
                                   sizeScore: volumeScore, score: min(1, max(0, score)), notes: notes)
    }

    /// Video names that form a numbered sequence are a strong sign of a recorded course.
    public static func sequenceScore(videos: [NetdiskEntry]) -> Double {
        var episodes: [String: Int] = [:]
        for video in videos { episodes[video.fid] = NetdiskTitles.episode(in: video.name) ?? 0 }
        return sequenceScore(videos: videos, episodes: episodes)
    }
    private static func sequenceScore(videos: [NetdiskEntry], episodes: [String: Int]) -> Double {
        guard videos.count >= 2 else { return videos.isEmpty ? 0 : 0.3 }
        let numbered = videos.compactMap { episodes[$0.fid] }.filter { $0 > 0 }
        let ratio = Double(numbered.count) / Double(videos.count)
        let continuity = Double(Set(numbered).count) / Double(max(1, numbered.count))
        return min(1, ratio * 0.7 + continuity * 0.3)
    }
}
