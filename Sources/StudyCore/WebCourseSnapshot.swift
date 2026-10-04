import Foundation

public struct WebCourseLesson: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var subject: String
    public var stage: String
    public var chapter: String
    public var kind: String
    public var published: Bool
    public var durationSeconds: Double?
    public var watchedPercent: Double?
    public var markedFinished: Bool
    public var requiresDuration: Bool
    public init(id: String, name: String, subject: String, stage: String, chapter: String,
                kind: String, published: Bool, durationSeconds: Double?, watchedPercent: Double?,
                markedFinished: Bool, requiresDuration: Bool) {
        self.id = id; self.name = name; self.subject = subject; self.stage = stage; self.chapter = chapter
        self.kind = kind; self.published = published; self.durationSeconds = durationSeconds
        self.watchedPercent = watchedPercent; self.markedFinished = markedFinished
        self.requiresDuration = requiresDuration
    }
    public var watchedSeconds: Double {
        guard let durationSeconds, let watchedPercent else { return 0 }
        return durationSeconds * watchedPercent / 100
    }
}

public struct WebCourseSnapshot: Codable, Equatable, Sendable {
    public var packageID: String
    public var name: String
    public var sourceURL: String
    public var fetchedAt: Date
    public var expectedOutlines: Int
    public var fetchedOutlines: Int
    public var lessons: [WebCourseLesson]
    public var issues: [String]
    /// Set only for courses read from a netdisk share; older snapshots decode as `nil`.
    public var netdisk: NetdiskSnapshot?
    public init(packageID: String, name: String, sourceURL: String, fetchedAt: Date,
                expectedOutlines: Int, fetchedOutlines: Int, lessons: [WebCourseLesson], issues: [String],
                netdisk: NetdiskSnapshot? = nil) {
        self.packageID = packageID; self.name = name; self.sourceURL = sourceURL; self.fetchedAt = fetchedAt
        self.expectedOutlines = expectedOutlines; self.fetchedOutlines = fetchedOutlines
        self.lessons = lessons; self.issues = issues; self.netdisk = netdisk
    }
    /// Decoded field by field so snapshots written before the netdisk feature still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packageID = try container.decode(String.self, forKey: .packageID)
        name = try container.decode(String.self, forKey: .name)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        expectedOutlines = try container.decode(Int.self, forKey: .expectedOutlines)
        fetchedOutlines = try container.decode(Int.self, forKey: .fetchedOutlines)
        lessons = try container.decode([WebCourseLesson].self, forKey: .lessons)
        issues = try container.decode([String].self, forKey: .issues)
        netdisk = try container.decodeIfPresent(NetdiskSnapshot.self, forKey: .netdisk)
    }
    public var totalSeconds: Double { timedLessons.reduce(0) { $0 + ($1.durationSeconds ?? 0) } }
    public var watchedSeconds: Double { timedLessons.reduce(0) { $0 + $1.watchedSeconds } }
    public var remainingSeconds: Double { max(0, totalSeconds - watchedSeconds) }
    public var totalMinutes: Int { Int(ceil(min(36_000_000, totalSeconds) / 60)) }
    public var remainingMinutes: Int { Int(ceil(min(36_000_000, remainingSeconds) / 60)) }
    public var completedMinutes: Int { max(0, totalMinutes - remainingMinutes) }
    public var timedLessons: [WebCourseLesson] { lessons.filter { $0.published && $0.requiresDuration } }
    public var unknownDurations: Int { timedLessons.filter { $0.durationSeconds == nil }.count }
    public var unknownProgress: Int { timedLessons.filter { $0.watchedPercent == nil }.count }
    public var importProblem: String? {
        if !issues.isEmpty || expectedOutlines != fetchedOutlines { return "抓取未完成，请重试；不会把部分结果当作完整课程。" }
        if lessons.isEmpty { return "该课程包暂无可读取课节。" }
        if Set(lessons.map(\.id)).count != lessons.count { return "课节标识重复，请重新抓取。" }
        if unknownDurations > 0 { return "有 \(unknownDurations) 节已发布视频缺少时长，暂不能生成准确计划。" }
        if unknownProgress > 0 { return "有 \(unknownProgress) 节缺少观看进度，暂不能确定剩余量。" }
        if lessons.contains(where: { lesson in
            if let seconds = lesson.durationSeconds, !seconds.isFinite || seconds <= 0 || seconds > 36_000_000 { return true }
            if let percent = lesson.watchedPercent, !percent.isFinite || percent < 0 || percent > 100 { return true }
            return lesson.id.isEmpty
        }) { return "网站返回的时长或观看进度无效。" }
        if !totalSeconds.isFinite || totalSeconds <= 0 || totalSeconds > 36_000_000 { return "可排程的总时长须大于零且不超过 10,000 小时。" }
        return nil
    }
    /// Website completion is cumulative; subtract app records rather than double counting them.
    public func applying(to course: Course, loggedMinutes: Int) -> Course? {
        guard importProblem == nil, loggedMinutes >= 0, loggedMinutes <= totalMinutes else { return nil }
        var result = course
        result.name = name
        result.totalMinutes = totalMinutes
        result.initialCompletedMinutes = max(0, completedMinutes - loggedMinutes)
        result.webCourse = self
        return result
    }
}

public enum WebCourseImportError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
public struct LessonWorkItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var subject: String
    public var stage: String
    public var chapter: String
    public var durationMinutes: Int
    public var remainingMinutes: Int
}

extension PlannerState {
    /// Undo only the local confirmation; progress verified by the website remains.
    func reconcilingWebsiteBaseline(for course: Course) -> Course {
        var updated = course
        if let sources = course.mergedSources {
            updated.mergedSources = sources.map {
                mergedSourceState(for: $0, in: course).reconcilingWebsiteBaseline(for: $0)
            }
            updated.initialCompletedMinutes = updated.mergedSources!.reduce(0) { $0 + $1.initialCompletedMinutes }
            return updated
        }
        guard let snapshot = course.webCourse, let overlaps = course.webCompletionOverlaps,
              snapshot.importProblem == nil, snapshot.totalMinutes == course.totalMinutes else { return updated }
        let known = Set(snapshot.timedLessons.map(\.id))
        let taskByID = Dictionary(tasks.filter { $0.courseID == course.id }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
        let records = completions.filter { $0.courseID == course.id }
        var earlier: [String: Int] = [:], unidentified = 0
        for record in records where record.recordedAt <= snapshot.fetchedAt {
            if let id = taskByID[record.taskID]?.lessonID, known.contains(id) { earlier[id, default: 0] += record.minutes }
            else { unidentified += record.minutes }
        }
        let remainingOverlaps = overlaps.mapValues { max(0, $0) }.map { id, amount in
            (id, min(amount, earlier[id, default: 0]))
        }
        let identified = remainingOverlaps.reduce(0) { $0 + $1.1 }
        let overlap = identified + min(unidentified, max(0, snapshot.completedMinutes - identified))
        updated.webCompletionOverlaps = Dictionary(uniqueKeysWithValues: remainingOverlaps)
        updated.initialCompletedMinutes = max(0, min(course.totalMinutes - records.reduce(0) { $0 + $1.minutes },
                                                     snapshot.completedMinutes - overlap))
        return updated
    }

    /// Round cumulative seconds once, so the lesson totals match the imported course total.
    public func lessonWorkItems(for course: Course) -> [LessonWorkItem] {
        guard course.type == .lessonBasedRecorded else { return [] }
        if let sources = course.mergedSources {
            return ordered(mergedWorkItems(for: course, sources: sources), for: course)
        }
        if course.webCourse == nil, let segments = course.manualLessons, !segments.isEmpty,
           segments.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.durationMinutes > 0 }),
           segments.reduce(0, { $0 + $1.durationMinutes }) == course.totalMinutes {
            var items = segments.map {
                LessonWorkItem(id: $0.id, name: $0.name, subject: "", stage: "", chapter: "",
                               durationMinutes: $0.durationMinutes, remainingMinutes: $0.durationMinutes)
            }
            var baseline = max(0, course.initialCompletedMinutes)
            for index in items.indices where baseline > 0 {
                let credit = min(baseline, items[index].remainingMinutes)
                items[index].remainingMinutes -= credit; baseline -= credit
            }
            let taskByID = Dictionary(uniqueKeysWithValues: tasks.filter { $0.courseID == course.id }.map { ($0.id, $0) })
            var unassigned = 0
            for record in completions where record.courseID == course.id {
                if let lessonID = taskByID[record.taskID]?.lessonID,
                   let index = items.firstIndex(where: { $0.id == lessonID }) {
                    let credit = min(record.minutes, items[index].remainingMinutes)
                    items[index].remainingMinutes -= credit
                    unassigned += record.minutes - credit
                } else { unassigned += record.minutes }
            }
            for index in items.indices where unassigned > 0 {
                let credit = min(unassigned, items[index].remainingMinutes)
                items[index].remainingMinutes -= credit; unassigned -= credit
            }
            return ordered(items, for: course)
        }
        guard let snapshot = course.webCourse,
              snapshot.importProblem == nil, snapshot.totalMinutes == course.totalMinutes else { return [] }
        var elapsed = 0.0, remaining = 0.0
        var items: [LessonWorkItem] = snapshot.timedLessons.map { lesson in
            let previousTotal = Int(ceil(elapsed / 60))
            let previousRemaining = Int(ceil(remaining / 60))
            elapsed += lesson.durationSeconds ?? 0
            remaining += max(0, (lesson.durationSeconds ?? 0) - lesson.watchedSeconds)
            return .init(id: lesson.id, name: lesson.name, subject: lesson.subject,
                         stage: lesson.stage, chapter: lesson.chapter,
                         durationMinutes: Int(ceil(elapsed / 60)) - previousTotal,
                         remainingMinutes: Int(ceil(remaining / 60)) - previousRemaining)
        }
        // The import reconciles website progress with the app ledger. Only progress beyond
        // that website snapshot needs to reduce its per-lesson remaining work.
        var extra = max(0, completedMinutes(for: course) - snapshot.completedMinutes)
        let websiteCredits = items.map { max(0, $0.durationMinutes - $0.remainingMinutes) }
        let taskByID = Dictionary(uniqueKeysWithValues: tasks.filter { $0.courseID == course.id }.map { ($0.id, $0) })
        for record in completions.filter({ $0.courseID == course.id && $0.recordedAt > snapshot.fetchedAt }) {
            guard extra > 0, let lessonID = taskByID[record.taskID]?.lessonID,
                  let index = items.firstIndex(where: { $0.id == lessonID }) else { continue }
            let credit = min(extra, record.minutes, items[index].remainingMinutes)
            items[index].remainingMinutes -= credit
            extra -= credit
        }
        // Refreshing the snapshot does not mean the website has caught up with local
        // confirmations. Keep their lesson identity, discounting progress already
        // represented by the website instead of applying it to the first lesson.
        var earlierCredits: [String: Int] = [:]
        for record in completions where record.courseID == course.id && record.recordedAt <= snapshot.fetchedAt {
            if let lessonID = taskByID[record.taskID]?.lessonID {
                earlierCredits[lessonID, default: 0] += record.minutes
            }
        }
        for index in items.indices where extra > 0 {
            let overlap = course.webCompletionOverlaps.map { $0[items[index].id, default: 0] } ?? websiteCredits[index]
            let outstanding = max(0, earlierCredits[items[index].id, default: 0] - overlap)
            let credit = min(extra, outstanding, items[index].remainingMinutes)
            items[index].remainingMinutes -= credit
            extra -= credit
        }
        for index in items.indices where extra > 0 {
            let credit = min(extra, items[index].remainingMinutes)
            items[index].remainingMinutes -= credit
            extra -= credit
        }
        return ordered(items, for: course)
    }

    private func ordered(_ items: [LessonWorkItem], for course: Course) -> [LessonWorkItem] {
        let order = LessonOrdering.resolved(ids: items.map(\.id), preferred: course.lessonOrder)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    public mutating func importWebCourses(_ snapshots: [WebCourseSnapshot], deadline: Date, now: Date) throws {
        guard !snapshots.isEmpty, Set(snapshots.map(\.packageID)).count == snapshots.count,
              deadline >= Calendar.current.startOfDay(for: now),
              deadline <= Calendar.current.date(byAdding: .year, value: 10, to: now)! else {
            throw WebCourseImportError.invalid("请选择课程并设置未来十年内的截止日期。")
        }
        var next = courses
        for snapshot in snapshots {
            let matches = next.indices.filter { next[$0].webCourse?.packageID == snapshot.packageID }
            guard matches.count <= 1 else { throw WebCourseImportError.invalid("已有多个课程绑定同一课程包，请先整理重复课程。") }
            let index = matches.first
            let course = index.map { next[$0] } ?? Course(name: snapshot.name, totalMinutes: 1, startDate: now, deadline: deadline)
            let logged = completions.filter { $0.courseID == course.id }.reduce(0) { $0 + $1.minutes }
            guard let updated = snapshot.applying(to: course, loggedMinutes: logged) else {
                throw WebCourseImportError.invalid(snapshot.name + "：" + (snapshot.importProblem ?? "已有完成流水超过网站课程总量，需人工核对。"))
            }
            var lessonBased = updated
            lessonBased.type = .lessonBasedRecorded
            // Only confirmations for the same lesson, made before this snapshot,
            // can overlap its website progress. A course-wide subtraction erases
            // independent work on other lessons, or work recorded after the fetch.
            let websiteCredits = Dictionary(PlannerState().lessonWorkItems(for: lessonBased).map {
                ($0.id, max(0, $0.durationMinutes - $0.remainingMinutes))
            }, uniquingKeysWith: { first, _ in first })
            let taskByID = Dictionary(tasks.filter { $0.courseID == course.id }.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
            var localCredits: [String: Int] = [:]
            var allLocalCredits: [String: Int] = [:]
            var unidentified = 0
            for record in completions where record.courseID == course.id {
                if let lessonID = taskByID[record.taskID]?.lessonID, websiteCredits[lessonID] != nil {
                    allLocalCredits[lessonID, default: 0] += record.minutes
                    if record.recordedAt <= snapshot.fetchedAt { localCredits[lessonID, default: 0] += record.minutes }
                } else if record.recordedAt <= snapshot.fetchedAt {
                    unidentified += record.minutes
                }
            }
            // Local confirmations can follow a partially watched website lesson.
            // Preserve that existing baseline before checking how much of the
            // newer website progress has caught up with those confirmations.
            let previousBaselines = Dictionary(lessonWorkItems(for: course).map {
                ($0.id, max(0, $0.durationMinutes - $0.remainingMinutes - (allLocalCredits[$0.id] ?? 0)))
            }, uniquingKeysWith: { first, _ in first })
            let overlaps = Dictionary(uniqueKeysWithValues: localCredits.map { id, minutes in
                (id, min(minutes, max(0, (websiteCredits[id] ?? 0) - (previousBaselines[id] ?? 0))))
            })
            let identifiedOverlap = overlaps.values.reduce(0, +)
            // Legacy records without a lesson identity retain the conservative
            // course-wide reconciliation; there is no evidence they are separate.
            let overlap = identifiedOverlap + min(unidentified, max(0, snapshot.completedMinutes - identifiedOverlap))
            lessonBased.initialCompletedMinutes = min(snapshot.totalMinutes - logged,
                                                      max(0, snapshot.completedMinutes - overlap))
            lessonBased.webCompletionOverlaps = overlaps
            // An archived course still matches its package ID. Importing it again is
            // an explicit request to put it back in the plan, using the chosen dates.
            if course.isArchived {
                lessonBased.isArchived = false
                lessonBased.autoScheduleEnabled = true
                lessonBased.startDate = now
                lessonBased.deadline = deadline
            }
            let followsWebsite: Bool
            if let customized = course.lessonOrderCustomized {
                followsWebsite = !customized
            } else if let oldOrder = course.lessonOrder, let oldSnapshot = course.webCourse {
                // Older imports generated this intelligent order automatically. Migrate
                // that default while preserving orders that the user moved by hand.
                let known = Set(oldOrder)
                let oldLessons = oldSnapshot.lessons.filter { known.contains($0.id) }
                followsWebsite = oldOrder == LessonOrdering.intelligentIDs(oldLessons)
            } else {
                followsWebsite = true
            }
            if followsWebsite {
                lessonBased.lessonOrder = snapshot.lessons.map(\.id)
                lessonBased.lessonOrderCustomized = false
            }
            if let index { next[index] = lessonBased } else { next.append(lessonBased) }
        }
        courses = next
    }
}
