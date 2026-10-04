import Foundation
import CryptoKit

/// What the plan needs to know about a netdisk course. It is stored with the course and synced,
/// so the numbers here are all plain scalars.
public struct NetdiskLessonMeta: Codable, Equatable, Sendable {
    public var fid: String
    public var path: String
    public var size: Int64
    public var width: Int?
    public var height: Int?
    /// True when the provider gave no duration and the course median was used instead.
    public var estimatedDuration: Bool
    /// Only ever filled inside the import window; the per-file share token is not written to disk.
    public var shareToken: String?
    public init(fid: String, path: String, size: Int64, width: Int?, height: Int?,
                estimatedDuration: Bool, shareToken: String? = nil) {
        self.fid = fid; self.path = path; self.size = size; self.width = width; self.height = height
        self.estimatedDuration = estimatedDuration; self.shareToken = shareToken
    }
    private enum CodingKeys: String, CodingKey { case fid, path, size, width, height, estimatedDuration }
}

/// A compact duplicate summary that is small enough to sync with the course.
public struct NetdiskDuplicateSummary: Codable, Equatable, Sendable {
    public var groups: [String]
    public var removedVideos: Int
    public var relatedPackages: [String]
    public var relatedCourses: [String]
    public var requiresReview: [String]
    public init(groups: [String], removedVideos: Int, relatedPackages: [String], relatedCourses: [String],
                requiresReview: [String]) {
        self.groups = groups; self.removedVideos = removedVideos; self.relatedPackages = relatedPackages
        self.relatedCourses = relatedCourses; self.requiresReview = requiresReview
    }
    public var isEmpty: Bool {
        groups.isEmpty && removedVideos == 0 && relatedPackages.isEmpty && relatedCourses.isEmpty
            && requiresReview.isEmpty
    }
    public static func compact(_ report: NetdiskDuplicateReport, packageID: String) -> NetdiskDuplicateSummary {
        let mine = report.droppedPackages.filter { $0.keptPackageID == packageID || $0.droppedPackageID == packageID }
        let within = report.withinCourses.filter { $0.packageID == packageID }
        return NetdiskDuplicateSummary(
            groups: within.prefix(5).map(\.summary),
            removedVideos: within.filter { !$0.requiresReview }.reduce(0) { $0 + $1.removed.count },
            relatedPackages: mine.prefix(3).map(\.summary),
            relatedCourses: report.existingCourseMatches.filter { $0.packageID == packageID }.map(\.reason),
            requiresReview: (within.filter(\.requiresReview).map(\.summary)
                             + mine.filter(\.requiresReview).map(\.summary)).prefix(3).map { $0 })
    }
}

/// Stored alongside a course that came from a netdisk share.
public struct NetdiskSnapshot: Codable, Equatable, Sendable {
    public var pwdID: String
    public var shareTitle: String
    /// Folder inside the share this course came from.
    public var folderPath: String
    public var sourceURL: String
    public var fetchedAt: Date
    public var videoCount: Int
    public var totalBytes: Int64
    public var unknownDurations: Int
    /// Why the folder was judged to be a course; shown in the import window.
    public var detection: String
    public var duplicates: NetdiskDuplicateSummary?
    /// All source packages when several recognized courses were imported as one.
    public var sourcePackageIDs: [String]?
    public init(pwdID: String, shareTitle: String, folderPath: String, sourceURL: String, fetchedAt: Date,
                videoCount: Int, totalBytes: Int64, unknownDurations: Int, detection: String,
                duplicates: NetdiskDuplicateSummary?, sourcePackageIDs: [String]? = nil) {
        self.pwdID = pwdID; self.shareTitle = shareTitle; self.folderPath = folderPath
        self.sourceURL = sourceURL; self.fetchedAt = fetchedAt; self.videoCount = videoCount
        self.totalBytes = totalBytes; self.unknownDurations = unknownDurations; self.detection = detection
        self.duplicates = duplicates
        self.sourcePackageIDs = sourcePackageIDs
    }
}

public enum NetdiskSnapshotBuilder {
    /// Below this many known durations the median is not trustworthy, so the course cannot be imported.
    public static let minimumKnownDurations = 3

    /// One importable course: the shared snapshot plus the per-lesson netdisk details.
    public struct Course: Sendable {
        public var snapshot: WebCourseSnapshot
        public var lessons: [String: NetdiskLessonMeta]
        public var refusal: String?
        public var packageID: String
        public var name: String
        public var videoCount: Int
        public var estimatedLessons: Int
        public var totalBytes: Int64
        public var detection: String
        public var notes: [String]
        public var sourcePackageIDs: [String] = []
    }

    /// Combines selected packages without losing each lesson's original file metadata.
    /// The ID depends on the member package IDs, so repeating the same merge updates one plan.
    public static func merge(_ sources: [Course], name: String, scan: NetdiskScan) -> Course? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = sources.map(\.packageID).sorted()
        guard sources.count >= 2, Set(ids).count == sources.count, !title.isEmpty,
              sources.allSatisfy({ $0.refusal == nil && !$0.snapshot.lessons.isEmpty }) else { return nil }

        let digest = SHA256.hash(data: Data(ids.joined(separator: "\n").utf8))
        let key = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let packageID = "quark:" + scan.pwdID + ":merged:" + key
        var seen = Set<String>()
        var lessons: [WebCourseLesson] = []
        var metadata: [String: NetdiskLessonMeta] = [:]
        let orderedSources = sources.sorted { lhs, rhs in
            let byName = NetdiskTitles.naturalCompare(lhs.name, rhs.name)
            return byName == .orderedSame ? lhs.packageID < rhs.packageID : byName == .orderedAscending
        }
        for source in orderedSources {
            let byID = Dictionary(source.snapshot.lessons.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let orderedLessons = LessonOrdering.intelligentIDs(source.snapshot.lessons).compactMap { byID[$0] }
            for var lesson in orderedLessons where seen.insert(lesson.id).inserted {
                if lesson.subject.isEmpty { lesson.subject = source.name }
                lessons.append(lesson)
                metadata[lesson.id] = source.lessons[lesson.id]
            }
        }
        guard metadata.count == lessons.count else { return nil }
        let snapshot = WebCourseSnapshot(packageID: packageID, name: title, sourceURL: scan.sourceURL,
                                         fetchedAt: scan.fetchedAt, expectedOutlines: 1, fetchedOutlines: 1,
                                         lessons: lessons, issues: [])
        let dropped = sources.reduce(0) { $0 + $1.snapshot.lessons.count } - lessons.count
        var notes = ["由 \(sources.count) 门课程合并；按来源课程、章节和课节编号智能排序"]
        if dropped > 0 { notes.append("跨课程重复文件 \(dropped) 个，已保留一份") }
        return Course(snapshot: snapshot, lessons: metadata, refusal: snapshot.importProblem,
                      packageID: packageID, name: title, videoCount: lessons.count,
                      estimatedLessons: metadata.values.filter(\.estimatedDuration).count,
                      totalBytes: metadata.values.reduce(0) { $0 + max(0, $1.size) },
                      detection: "由 \(sources.count) 门课程合并", notes: notes,
                      sourcePackageIDs: ids)
    }

    /// Assembles one course package into the same snapshot type the website reader produces,
    /// so persistence, scheduling and syncing need no netdisk-specific path.
    public static func build(package: NetdiskPackage, scan: NetdiskScan) -> Course? {
        let videos = package.videos
        let known = videos.compactMap { NetdiskDigest.duration($0) }.sorted()
        let unknown = videos.count - known.count
        let usedMedian = known.isEmpty ? 0 : max(known[known.count / 2], 60)
        let name = displayName(package: package, scan: scan)
        let detection = detectionSummary(package)
        var notes: [String] = package.signal.notes
        if package.documentCount > 0 { notes.append("目录内另有 \(package.documentCount) 个文档，不计入学习量") }
        if unknown > 0, !known.isEmpty {
            notes.append("\(unknown) 个视频缺时长，已按该课程中位数 \(WebLessonTiming.clock(usedMedian)) 估算")
        }

        func refuse(_ reason: String) -> Course {
            Course(snapshot: WebCourseSnapshot(packageID: package.packageID, name: name,
                                               sourceURL: scan.sourceURL, fetchedAt: scan.fetchedAt,
                                               expectedOutlines: 1, fetchedOutlines: 1, lessons: [], issues: []),
                   lessons: [:], refusal: reason, packageID: package.packageID, name: name,
                   videoCount: videos.count, estimatedLessons: 0, totalBytes: package.totalBytes,
                   detection: detection, notes: notes)
        }
        guard !videos.isEmpty else { return refuse("该目录下没有可用的视频。") }
        guard Set(videos.map(\.fid)).count == videos.count else { return refuse("视频标识重复，请重新抓取。") }
        guard !videos.contains(where: { $0.fid.isEmpty || $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return refuse("网站返回了不完整的视频条目。") }
        if unknown == videos.count { return refuse("网盘没有提供任何视频时长，无法估算学习量。") }
        if unknown > 0, known.count < minimumKnownDurations {
            return refuse("有 \(unknown) 个视频没有时长，且已知时长的视频不足 \(minimumKnownDurations) 个，无法估算学习量。")
        }

        var counts: [String: Int] = [:]
        var lessons: [WebCourseLesson] = []
        var meta: [String: NetdiskLessonMeta] = [:]
        // Digest already placed the package's videos in natural lesson order.
        for video in videos {
            let occurrence = (counts[video.fid] ?? 0) + 1
            counts[video.fid] = occurrence
            let id = "quark:" + scan.pwdID + ":" + video.fid + (occurrence > 1 ? ":\(occurrence)" : "")
            let duration = NetdiskDigest.duration(video)
            lessons.append(WebCourseLesson(
                id: id, name: lessonName(video), subject: "", stage: "",
                chapter: video.parentPath, kind: "video", published: true,
                durationSeconds: duration ?? usedMedian, watchedPercent: 0, markedFinished: false,
                requiresDuration: true))
            meta[id] = NetdiskLessonMeta(fid: video.fid, path: video.relativePath, size: max(0, video.size),
                                         width: video.width, height: video.height,
                                         estimatedDuration: duration == nil, shareToken: video.shareToken)
        }
        let snapshot = WebCourseSnapshot(packageID: package.packageID, name: name, sourceURL: scan.sourceURL,
                                         fetchedAt: scan.fetchedAt, expectedOutlines: 1, fetchedOutlines: 1,
                                         lessons: lessons, issues: [])
        // `issues` denotes an incomplete crawl in WebCourseSnapshot. Netdisk notes such as
        // estimated durations are informational and must not make a complete course invalid.
        return Course(snapshot: snapshot, lessons: meta, refusal: snapshot.importProblem,
                      packageID: package.packageID, name: name,
                      videoCount: videos.count, estimatedLessons: unknown, totalBytes: package.totalBytes,
                      detection: detection, notes: notes)
    }

    /// `01.抢跑预备` inside `02 课程/01 视频` reads better as `01 视频 · 01.抢跑预备`; a course at the
    /// share root keeps its own name.
    public static func displayName(package: NetdiskPackage, scan: NetdiskScan) -> String {
        let own = NetdiskTitles.displayName(package.name)
        guard !package.path.isEmpty else { return own.isEmpty ? scan.displayName : own }
        let segments = package.path.split(separator: "/").map { NetdiskTitles.displayName(String($0)) }
        guard let parent = segments.dropLast().last, !parent.isEmpty, !own.isEmpty else {
            return own.isEmpty ? scan.displayName : own
        }
        // The parent folder's name is often part of the child's, so do not repeat it.
        guard !own.contains(parent), !parent.contains(own) else { return own }
        return parent + " · " + own
    }

    /// Lesson titles keep the episode number the file carries, minus the extension.
    public static func lessonName(_ entry: NetdiskEntry) -> String {
        var name = entry.name
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            let suffix = name[name.index(after: dot)...]
            if !suffix.isEmpty, suffix.count <= 5, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                name = String(name[..<dot])
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? entry.name : trimmed
    }

    private static func detectionSummary(_ package: NetdiskPackage) -> String {
        let signal = package.signal
        var parts = ["视频占比 \(Int((signal.videoRatio * 100).rounded()))%",
                     "课程判定 \(Int((signal.score * 100).rounded())) 分"]
        if !signal.notes.isEmpty { parts.append(signal.notes.joined(separator: "；")) }
        return parts.joined(separator: "，")
    }
}

extension PlannerState {
    /// Saves the ordered lessons and their source file metadata with the ordinary course plan.
    public mutating func importNetdiskCourses(_ candidates: [NetdiskSnapshotBuilder.Course],
                                              scan: NetdiskScan, duplicates: NetdiskDuplicateReport,
                                              deadline: Date, now: Date) throws {
        let availableIDs = Set(scan.packages.map(\.packageID))
        for candidate in candidates {
            let sourceIDs = candidate.sourcePackageIDs.isEmpty ? [candidate.packageID] : candidate.sourcePackageIDs
            guard Set(sourceIDs).isSubset(of: availableIDs) else {
                throw WebCourseImportError.invalid(candidate.name + "：来源目录不完整，请重新读取分享。")
            }
        }
        try importWebCourses(candidates.map(\.snapshot), deadline: deadline, now: now)
        for candidate in candidates {
            guard let index = courses.firstIndex(where: { $0.webCourse?.packageID == candidate.packageID }) else { continue }
            let sourceIDs = candidate.sourcePackageIDs.isEmpty ? [candidate.packageID] : candidate.sourcePackageIDs
            let paths = sourceIDs.compactMap { id in scan.packages.first(where: { $0.packageID == id })?.path }
            let folderPath = paths.count == 1 ? paths[0] : "合并自 \(paths.count) 个目录"
            courses[index].netdisk = NetdiskSnapshot(
                pwdID: scan.pwdID, shareTitle: scan.title, folderPath: folderPath,
                sourceURL: scan.sourceURL, fetchedAt: scan.fetchedAt,
                videoCount: candidate.videoCount, totalBytes: candidate.totalBytes,
                unknownDurations: candidate.estimatedLessons, detection: candidate.detection,
                duplicates: NetdiskDuplicateSummary.compact(duplicates, packageID: candidate.packageID),
                sourcePackageIDs: candidate.sourcePackageIDs.isEmpty ? nil : sourceIDs)
            courses[index].netdiskLessons = candidate.lessons
        }
    }
}
