import Foundation

/// Result of the duplicate scan: what is certainly a copy, what is probably one, and what is
/// probably the same course under a different name.
public struct NetdiskDuplicateReport: Codable, Equatable, Sendable {
    public var withinCourses: [NetdiskDuplicateGroup]
    public var droppedPackages: [NetdiskPackageDuplicate]
    public var existingCourseMatches: [NetdiskCourseMatch]
    public var checkedCourses: Int
    public var checkedVideos: Int
    public init(withinCourses: [NetdiskDuplicateGroup] = [], droppedPackages: [NetdiskPackageDuplicate] = [],
                existingCourseMatches: [NetdiskCourseMatch] = [], checkedCourses: Int = 0,
                checkedVideos: Int = 0) {
        self.withinCourses = withinCourses; self.droppedPackages = droppedPackages
        self.existingCourseMatches = existingCourseMatches
        self.checkedCourses = checkedCourses; self.checkedVideos = checkedVideos
    }
    public var removedVideoCount: Int { withinCourses.reduce(0) { $0 + $1.removed.count } }
    /// Loose duplicates are reported but never removed on their own.
    public var reviewCount: Int {
        withinCourses.filter { $0.requiresReview }.count + droppedPackages.filter { $0.requiresReview }.count
    }
    public var isEmpty: Bool {
        withinCourses.isEmpty && droppedPackages.isEmpty && existingCourseMatches.isEmpty
    }
}

public struct NetdiskDuplicateEntry: Codable, Equatable, Sendable, Identifiable {
    public var fid: String
    public var name: String
    public var path: String
    public var size: Int64
    public var durationSeconds: Double?
    public var resolution: Int
    public var reason: String
    public var id: String { fid }
}

public struct NetdiskDuplicateGroup: Codable, Equatable, Sendable, Identifiable {
    public var packageID: String
    public var courseName: String
    public var retained: NetdiskDuplicateEntry
    public var removed: [NetdiskDuplicateEntry]
    public var requiresReview: Bool
    public var reason: String
    public var id: String { packageID + "|" + retained.fid }
    public var summary: String {
        requiresReview
            ? "《\(courseName)》中「\(retained.name)」有 \(removed.count + 1) 个疑似版本；\(reason)"
            : "《\(courseName)》中「\(retained.name)」有 \(removed.count + 1) 个副本；\(reason)"
    }
}

public struct NetdiskPackageDuplicate: Codable, Equatable, Sendable, Identifiable {
    public var keptPackageID: String
    public var droppedPackageID: String
    public var keptName: String
    public var droppedName: String
    public var overlapRatio: Double
    public var score: Double
    /// High-confidence duplicates are dropped automatically; the rest are listed for a decision.
    public var requiresReview: Bool
    public var reason: String
    public var id: String { keptPackageID + "|" + droppedPackageID }
    public var summary: String {
        "《\(droppedName)》与《\(keptName)》课节重合 \(Int((overlapRatio * 100).rounded()))%，\(reason)"
    }
}

public struct NetdiskCourseMatch: Codable, Equatable, Sendable, Identifiable {
    public var packageID: String
    public var packageName: String
    public var courseID: UUID
    public var courseName: String
    public var overlapRatio: Double
    public var score: Double
    public var reason: String
    public var id: String { packageID + "|" + courseID.uuidString }
}

public enum NetdiskDedup {
    /// Copies must agree this closely on size to be treated as the same encode.
    public static let sameEncodeTolerance = 0.025
    /// Above this, names still count as the same lesson after removing numbering.
    public static let looseNameThreshold = 0.86
    public static let autoDropScore = 0.90
    public static let reviewScore = 0.72
    private static let genericLessonNames: Set<String> = [
        "视频", "讲解", "视频讲解", "课程", "课件", "习题", "测试", "答案", "解析", "例题", "导学"
    ]
    private static let bareCounter = try! NSRegularExpression(
        pattern: #"^第[0-9０-９一二三四五六七八九十百零〇两]{1,4}[题讲课节集章](?:视频)?(?:讲解|解析|测试)?$"#)

    private static func informativeIdentity(_ name: String) -> String? {
        let parsed = NetdiskTitles.parse(name)
        let base = parsed.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.count >= 2, !genericLessonNames.contains(base) else { return nil }
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        guard bareCounter.firstMatch(in: base, range: range) == nil else { return nil }
        return base + "|" + (parsed.episode.map { String(format: "%04d", $0) } ?? "")
    }

    public struct Candidate: Equatable, Sendable {
        public var packageID: String
        public var name: String
        public var path: String
        public var videos: [NetdiskEntry]
        public var looseIdentities: [String]
        public var durationSeconds: Double
        public var totalBytes: Int64
        public var minHeight: Int
        public init(packageID: String, name: String, path: String, videos: [NetdiskEntry],
                    looseIdentities: [String], durationSeconds: Double, totalBytes: Int64, minHeight: Int) {
            self.packageID = packageID; self.name = name; self.path = path; self.videos = videos
            self.looseIdentities = looseIdentities; self.durationSeconds = durationSeconds
            self.totalBytes = totalBytes; self.minHeight = minHeight
        }
    }

    /// Keep chapter context: many courses restart at 第1讲 in each chapter.
    public static func groupWithinCourse(_ videos: [NetdiskEntry]) -> [(kept: NetdiskEntry, dropped: NetdiskEntry, reason: String)] {
        var buckets: [String: [NetdiskEntry]] = [:]
        for video in videos where NetdiskDigest.isVideo(video) {
            if let duration = video.durationSeconds, duration < 5 { continue }
            let identity = NetdiskTitles.looseIdentity(video.name)
            buckets[video.parentPath + "|" + identity, default: []].append(video)
        }
        var pairs: [(kept: NetdiskEntry, dropped: NetdiskEntry, reason: String)] = []
        for bucket in buckets.values where bucket.count > 1 {
            let ranked = bucket.sorted { quality($0) > quality($1) }
            for loser in ranked.dropFirst() {
                pairs.append((ranked[0], loser, "时长、清晰度与体积最好的那一份"))
            }
        }
        return pairs
    }

    /// Higher is better: resolution, then duration, then bytes.
    public static func quality(_ entry: NetdiskEntry) -> Int64 {
        let pixels = Int64(min(entry.width ?? 0, entry.height ?? 0))
        let seconds = Int64((entry.durationSeconds ?? 0).rounded())
        return pixels * 100_000_000 + min(seconds, 99_999) * 1_000 + min(entry.size / 1_048_576, 999)
    }

    /// The same lesson under a different name or numbering.
    public static func looseMatches(_ lhs: NetdiskEntry, _ rhs: NetdiskEntry) -> Bool {
        let left = NetdiskTitles.parse(lhs.name), right = NetdiskTitles.parse(rhs.name)
        if left.episode != nil, right.episode != nil, left.episode != right.episode { return false }
        if !left.base.isEmpty, left.base == right.base { return true }
        return NetdiskTitles.similarity(lhs.name, rhs.name) >= looseNameThreshold
    }

    /// True only when both courses list exactly the same lessons: the signature of a real duplicate.
    public static func hasIdenticalLessons(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = Set(lhs.looseIdentities.filter { !$0.isEmpty })
        let right = Set(rhs.looseIdentities.filter { !$0.isEmpty })
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right
    }

    /// How much of the smaller course also appears in the larger one, by loose lesson identity.
    public static func overlap(_ lhs: Candidate, _ rhs: Candidate) -> Double {
        let left = Set(lhs.looseIdentities.filter { !$0.isEmpty })
        let right = Set(rhs.looseIdentities.filter { !$0.isEmpty })
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let intersection = left.intersection(right).count
        return Double(intersection) / Double(min(left.count, right.count))
    }

    /// Weighted similarity of two courses.
    ///
    /// The lesson list is the evidence, so it carries the weight; a course name is only supporting
    /// detail, because the same course is routinely filed under different folder names. A matching
    /// name lifts a partial match into "ask the user" without ever dropping anything on its own.
    public static func score(_ lhs: Candidate, _ rhs: Candidate) -> Double {
        let title = NetdiskTitles.similarity(lhs.name, rhs.name)
        let lessons = overlap(lhs, rhs)
        let counts = ratio(Double(lhs.videos.count), Double(rhs.videos.count))
        let durations = ratio(lhs.durationSeconds, rhs.durationSeconds)
        let sizes = ratio(Double(lhs.totalBytes), Double(rhs.totalBytes))
        // A different folder name is not evidence against a duplicate when the lessons are identical.
        let effectiveTitle = hasIdenticalLessons(lhs, rhs) ? max(title, 0.5) : title
        return 0.62 * lessons + 0.13 * effectiveTitle + (0.25 / 3) * (counts + durations + sizes)
    }

    private static func ratio(_ lhs: Double, _ rhs: Double) -> Double {
        let high = max(lhs, rhs), low = min(lhs, rhs)
        guard high > 0 else { return 1 }
        return low / high
    }

    public static func candidate(for package: NetdiskPackage) -> Candidate {
        Candidate(packageID: package.packageID, name: package.name, path: package.path,
                  videos: package.videos,
                  looseIdentities: package.videos.map { informativeIdentity($0.name) ?? "" },
                  durationSeconds: package.totalSeconds, totalBytes: package.totalBytes,
                  minHeight: package.minHeight)
    }

    /// Works on package summaries, not the original entries, so the report stays small enough to sync.
    public static func scan(packages: [NetdiskPackage], courses: [Course] = []) -> NetdiskDuplicateReport {
        var report = NetdiskDuplicateReport()
        report.checkedCourses = packages.count
        report.checkedVideos = packages.reduce(0) { $0 + $1.videoCount }
        for package in packages {
            let pairs = groupWithinCourse(package.videos)
            guard !pairs.isEmpty else { continue }
            var grouped: [String: (kept: NetdiskEntry, removed: [NetdiskEntry], reason: String)] = [:]
            for pair in pairs {
                var bucket = grouped[pair.kept.fid] ?? (pair.kept, [], pair.reason)
                bucket.removed.append(pair.dropped)
                grouped[pair.kept.fid] = bucket
            }
            for bucket in grouped.values {
                let requiresReview = bucket.removed.contains { copy in
                    guard bucket.kept.size > 0, copy.size > 0,
                          let keptDuration = NetdiskDigest.duration(bucket.kept),
                          let copyDuration = NetdiskDigest.duration(copy) else { return true }
                    let sizeDifference = abs(Double(copy.size - bucket.kept.size)) / Double(bucket.kept.size)
                    let durationDifference = abs(copyDuration - keptDuration) / max(copyDuration, keptDuration)
                    return sizeDifference > sameEncodeTolerance || durationDifference > 0.03
                }
                report.withinCourses.append(NetdiskDuplicateGroup(
                    packageID: package.packageID, courseName: package.name,
                    retained: describe(bucket.kept, reason: "体积最大"),
                    removed: bucket.removed.map { describe($0, reason: "重复副本") },
                    requiresReview: requiresReview,
                    reason: requiresReview ? "文件大小或时长不同，导入时暂时保留全部" : "大小与时长接近，导入时只保留最佳的一份"))
            }
        }
        report.withinCourses.sort { $0.packageID == $1.packageID ? $0.retained.fid < $1.retained.fid : $0.packageID < $1.packageID }

        let candidates = packages.map(candidate(for:))
        let lessonSets = candidates.map { Set($0.looseIdentities.filter { !$0.isEmpty }) }
        var dropped: Set<String> = []
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                let lhs = candidates[i], rhs = candidates[j]
                if dropped.contains(lhs.packageID) || dropped.contains(rhs.packageID) { continue }
                let left = lessonSets[i], right = lessonSets[j]
                guard !left.isEmpty, !right.isEmpty else { continue }
                let overlapRatio = Double(left.intersection(right).count) / Double(min(left.count, right.count))
                guard overlapRatio >= 0.5 else { continue }
                let value = score(lhs, rhs)
                guard value >= reviewScore else { continue }
                // A course that is only a subset, or differs by a lesson, is never dropped silently.
                let auto = value >= autoDropScore && min(lhs.videos.count, rhs.videos.count) >= 3
                    && hasIdenticalLessons(lhs, rhs)
                    && ratio(lhs.durationSeconds, rhs.durationSeconds) >= 0.95
                    && ratio(Double(lhs.totalBytes), Double(rhs.totalBytes)) >= 0.85
                let keepLeft = keepFirst(lhs, rhs)
                let kept = keepLeft ? lhs : rhs, loser = keepLeft ? rhs : lhs
                if auto { dropped.insert(loser.packageID) }
                report.droppedPackages.append(NetdiskPackageDuplicate(
                    keptPackageID: kept.packageID, droppedPackageID: loser.packageID,
                    keptName: kept.name, droppedName: loser.name, overlapRatio: overlapRatio, score: value,
                    requiresReview: !auto,
                    reason: auto
                        ? "判定为同一门课，自动保留内容更完整的一份"
                        : "相似度 \(Int((value * 100).rounded()))%，请确认是否只需导入一份"))
            }
        }
        // Only fully-automatic drops are removed outright; reviewed ones stay and stay selectable.
        report.droppedPackages.sort { $0.droppedPackageID < $1.droppedPackageID }

        for package in packages {
            let matched = courses.compactMap { course -> NetdiskCourseMatch? in
                let lessons = course.webCourse?.lessons.map(\.name) ?? course.manualLessons?.map(\.name) ?? []
                guard !lessons.isEmpty, !package.videos.isEmpty else { return nil }
                let mine = Set(package.videos.compactMap { informativeIdentity($0.name) })
                let theirs = Set(lessons.compactMap { informativeIdentity($0) })
                guard !mine.isEmpty, !theirs.isEmpty else { return nil }
                let shared = Double(mine.intersection(theirs).count) / Double(min(mine.count, theirs.count))
                guard shared >= 0.6 else { return nil }
                let value = 0.5 * shared + 0.5 * NetdiskTitles.similarity(package.name, course.name)
                return NetdiskCourseMatch(packageID: package.packageID, packageName: package.name,
                                          courseID: course.id, courseName: course.name,
                                          overlapRatio: shared, score: value,
                                          reason: shared >= 0.9
                                              ? "课节几乎完全相同，请核对是否已有这门课"
                                              : "有 \(Int((shared * 100).rounded()))% 课节相同，可能是同一门课的不同版本")
            }.sorted { $0.score > $1.score }
            report.existingCourseMatches.append(contentsOf: matched.prefix(1))
        }
        return report
    }

    public static func keepFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        func rank(_ value: Candidate) -> (Double, Int64, Int) {
            (value.durationSeconds, value.totalBytes, value.minHeight)
        }
        let a = rank(lhs), b = rank(rhs)
        if a.0 != b.0 { return a.0 > b.0 }
        if a.1 != b.1 { return a.1 > b.1 }
        if a.2 != b.2 { return a.2 > b.2 }
        return lhs.packageID < rhs.packageID
    }

    /// Drops the automatically-detected duplicate packages and keeps everything else.
    public static func applied(_ packages: [NetdiskPackage], report: NetdiskDuplicateReport) -> [NetdiskPackage] {
        let auto = Set(report.droppedPackages.filter { !$0.requiresReview }.map(\.droppedPackageID))
        return packages.filter { !auto.contains($0.packageID) }
    }

    /// Near-identical file copies can be omitted from the imported lesson list. Other variants
    /// stay visible because a change in size or duration may mean different content.
    public static func removingSafeCopies(from package: NetdiskPackage,
                                          report: NetdiskDuplicateReport) -> NetdiskPackage {
        let removed = Set(report.withinCourses
            .filter { $0.packageID == package.packageID && !$0.requiresReview }
            .flatMap { $0.removed.map(\.fid) })
        guard !removed.isEmpty else { return package }
        var result = package
        result.videos.removeAll { removed.contains($0.fid) }
        result.totalBytes = result.videos.reduce(0) { $0 + max(0, $1.size) }
        result.totalSeconds = result.videos.reduce(0) { $0 + (NetdiskDigest.duration($1) ?? 0) }
        result.unknownDurations = result.videos.filter { NetdiskDigest.duration($0) == nil }.count
        return result
    }

    private static func describe(_ entry: NetdiskEntry, reason: String) -> NetdiskDuplicateEntry {
        NetdiskDuplicateEntry(fid: entry.fid, name: entry.name, path: entry.relativePath, size: entry.size,
                              durationSeconds: entry.durationSeconds,
                              resolution: min(entry.width ?? 0, entry.height ?? 0), reason: reason)
    }
}
