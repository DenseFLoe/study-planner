import Foundation

/// One same-origin JSON response captured by the injected sniffer.
public struct CapturedResponse: Sendable, Equatable {
    public let url: String
    public let body: String
    public init(url: String, body: String) {
        self.url = url
        self.body = body
    }
}

/// Framework-agnostic reader: finds courses and lessons in whatever JSON a site already returned.
/// It never assumes a router, a bundler or a naming scheme beyond common duration and progress spellings.
public enum GenericCourseDigest {
    public static func snapshots(from responses: [CapturedResponse], pageURL: String, pageTitle: String = "",
                                 now: Date) -> [WebCourseSnapshot] {
        var drafts: [String: CourseDraft] = [:]
        var order: [String] = []
        for response in responses {
            guard let data = response.body.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { continue }
            var nodes: [Node] = []
            build(root, parent: nil, isArrayElement: false, sourceURL: response.url, depth: 0, into: &nodes)
            for node in nodes where node.lesson == nil { node.lesson = lessonDraft(node.object) }
            for node in nodes {
                guard let lesson = node.lesson else { continue }
                let key: String, name: String, source: String
                if let own = lesson.courseKey, !own.isEmpty {
                    // A lesson that names its own course groups by it, so chapters of one course stay together.
                    key = normalized(own)
                    let pageLabel = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    name = lesson.courseLabel
                        ?? nodes.first.flatMap { nameField($0.object) }
                        ?? (pageLabel.isEmpty ? nil : pageLabel)
                        ?? container(of: node).map { courseName($0, pageURL: pageURL, pageTitle: pageTitle) }
                        ?? fallbackName(pageURL: pageURL, pageTitle: pageTitle)
                    source = node.sourceURL
                } else if let container = container(of: node) {
                    key = courseKey(container, pageURL: pageURL, pageTitle: pageTitle)
                    name = courseName(container, pageURL: pageURL, pageTitle: pageTitle)
                    source = container.sourceURL
                } else {
                    continue
                }
                if drafts[key] == nil {
                    drafts[key] = CourseDraft(key: key, name: name, sourceURL: source, lessons: [])
                    order.append(key)
                }
                drafts[key]?.lessons.append(lesson)
            }
        }
        var result: [WebCourseSnapshot] = []
        var used: Set<String> = []
        for key in order {
            guard let draft = drafts[key], !draft.lessons.isEmpty else { continue }
            var packageID = "generic:" + key
            var suffix = 2
            while used.contains(packageID) { packageID = "generic:" + key + "#" + String(suffix); suffix += 1 }
            used.insert(packageID)
            result.append(draft.snapshot(packageID: packageID, now: now))
        }
        return result.sorted { $0.lessons.count > $1.lessons.count }
    }
}

// MARK: - Tree walk

private final class Node {
    let object: [String: Any]
    let parent: Node?
    let isArrayElement: Bool
    let sourceURL: String
    var lesson: Lesson?
    init(object: [String: Any], parent: Node?, isArrayElement: Bool, sourceURL: String) {
        self.object = object
        self.parent = parent
        self.isArrayElement = isArrayElement
        self.sourceURL = sourceURL
    }
}

private struct Lesson {
    var name: String
    var identifier: String
    /// A plain number, still subject to the course-wide seconds/milliseconds decision.
    var durationRaw: Double?
    /// Already an exact number of seconds, because the site formatted it for display.
    var durationText: Double?
    var percentRaw: Double?
    var positionRaw: Double?
    var markedFinished: Bool
    /// Set when the lesson itself names the course it belongs to, which is the most reliable grouping.
    var courseKey: String?
    var courseLabel: String?
}

private struct CourseDraft {
    let key: String
    let name: String
    let sourceURL: String
    var lessons: [Lesson]

    func snapshot(packageID: String, now: Date) -> WebCourseSnapshot {
        // One response reports one unit for every lesson, so the scale is decided per course, not per value.
        let durationRaws = lessons.compactMap(\.durationRaw)
        let usesMilliseconds = (durationRaws.max() ?? 0) > 36_000
        let progressRaws = lessons.compactMap(\.percentRaw)
        let usesRatio = !progressRaws.isEmpty && progressRaws.allSatisfy { $0 <= 1 }
        var seen: Set<String> = []
        var built: [WebCourseLesson] = []
        for lesson in lessons {
            let identifier = lesson.identifier.isEmpty ? lesson.name : lesson.identifier
            let id = packageID + ":" + identifier
            guard seen.insert(id).inserted else { continue }
            let seconds = lesson.durationText ?? lesson.durationRaw.flatMap { Self.seconds($0, milliseconds: usesMilliseconds) }
            var percent = lesson.percentRaw.flatMap { Self.percentage($0, asRatio: usesRatio) }
            if percent == nil, let position = lesson.positionRaw, let seconds, position > 0 {
                let played = usesMilliseconds ? position / 1000 : position
                if played <= seconds { percent = min(100, max(0, played / seconds * 100)) }
            }
            built.append(WebCourseLesson(id: id, name: lesson.name, subject: "", stage: "", chapter: "",
                                         kind: seconds == nil ? "unknown" : "video", published: true,
                                         durationSeconds: seconds, watchedPercent: percent ?? 0,
                                         markedFinished: lesson.markedFinished, requiresDuration: seconds != nil))
        }
        return WebCourseSnapshot(packageID: packageID, name: name, sourceURL: sourceURL, fetchedAt: now,
                                 expectedOutlines: 1, fetchedOutlines: 1, lessons: built, issues: [])
    }

    /// Durations arrive in seconds or milliseconds; the impossible reading for the whole course is corrected.
    static func seconds(_ raw: Double, milliseconds: Bool) -> Double? {
        guard raw.isFinite, raw > 0 else { return nil }
        let value = milliseconds ? raw / 1000 : raw
        guard value >= 1, value <= 36_000 else { return nil }
        return value
    }

    /// Watch state arrives either as a 0–1 ratio or as a 0–100 percentage.
    static func percentage(_ raw: Double, asRatio: Bool) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }
        let value = asRatio ? raw * 100 : raw
        guard value <= 100 else { return nil }
        return value
    }
}

private extension GenericCourseDigest {
    static let maxNodes = 250_000
    static let finishKeys: Set<String> = ["finished", "isfinish", "completed", "iscompleted", "finishstatus"]

    static func build(_ value: Any, parent: Node?, isArrayElement: Bool, sourceURL: String, depth: Int, into nodes: inout [Node]) {
        guard depth < 40, nodes.count < maxNodes else { return }
        if let object = value as? [String: Any] {
            let node = Node(object: object, parent: parent, isArrayElement: isArrayElement, sourceURL: sourceURL)
            nodes.append(node)
            for (_, child) in object {
                build(child, parent: node, isArrayElement: false, sourceURL: sourceURL, depth: depth + 1, into: &nodes)
            }
        } else if let array = value as? [Any] {
            for child in array {
                build(child, parent: parent, isArrayElement: true, sourceURL: sourceURL, depth: depth + 1, into: &nodes)
            }
        }
    }

    /// A course is the outermost list item above the lesson, so chapters nested inside a package stay together.
    static func container(of node: Node) -> Node? {
        var outermost: Node?
        var current = node.parent
        var hops = 0
        while let value = current, hops < 12 {
            if value.isArrayElement, value.lesson == nil { outermost = value }
            current = value.parent
            hops += 1
        }
        return outermost ?? node.parent
    }

    static func courseKey(_ container: Node, pageURL: String, pageTitle: String) -> String {
        let name = normalized(courseName(container, pageURL: pageURL, pageTitle: pageTitle))
        if !name.isEmpty { return name }
        if let identifier = identifierField(container.object), !identifier.isEmpty { return normalized(identifier) }
        return "page"
    }

    static func courseName(_ container: Node, pageURL: String, pageTitle: String) -> String {
        var current: Node? = container
        var hops = 0
        while let node = current, hops < 3 {
            if let name = nameField(node.object) { return name }
            current = node.parent
            hops += 1
        }
        return fallbackName(pageURL: pageURL, pageTitle: pageTitle)
    }

    /// When nothing in the payload names the course, the page the user was reading usually does.
    static func fallbackName(pageURL: String, pageTitle: String) -> String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains("\n") { return trimmed }
        if let host = URL(string: pageURL)?.host, !host.isEmpty { return host }
        return "网页课程"
    }

    // MARK: Field naming

    static func normalized(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static let nameKeys = ["name", "title", "coursename", "lessonname", "sectionname", "chaptername", "catalogname",
                           "videoname", "subjectname", "packagename", "goodsname", "productname", "outlinename",
                           "kcmc", "kjmc", "deliveryname"]
    /// Lesson-level identity only: a course or package id here would collapse every lesson into one.
    static let idKeys = ["id", "uuid", "lessonid", "sectionid", "catalogid", "videoid", "chapterid",
                         "resourceid", "cid", "kid", "_id"]
    /// A lesson that carries its own course identity groups the whole course even when chapters nest it.
    static let courseIdKeys = ["courseid", "coursecode", "courseuuid", "kcdm"]
    static let courseNameKeys = ["coursename", "coursetitle"]
    static let durationKeys: Set<String> = ["duration", "length", "seconds", "videotime", "playtime", "timelength",
                                            "totaltime", "totalseconds", "videoduration", "mediaduration",
                                            "lessonduration", "courseduration", "classduration", "shichang"]
    static let progressKeys: Set<String> = ["percent", "progress", "rate", "watched", "schedule", "jd",
                                            "learnpercent", "learnprogress", "studyprogress", "watchprogress",
                                            "playprogress", "finishedpercent", "completerate", "finishrate"]

    static func nameField(_ object: [String: Any]) -> String? {
        for key in nameKeys {
            for (candidate, value) in object where normalized(candidate) == key {
                guard let text = value as? String else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count <= 200, !trimmed.contains("\n") { return trimmed }
            }
        }
        return nil
    }

    static func identifierField(_ object: [String: Any]) -> String? {
        for key in idKeys {
            for (candidate, value) in object where normalized(candidate) == key {
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    return number.stringValue
                }
                if let text = value as? String, !text.isEmpty, text.count <= 64 { return text }
            }
        }
        return nil
    }

    static func lessonDraft(_ object: [String: Any]) -> Lesson? {
        guard let name = nameField(object) else { return nil }
        var duration: Double?
        var durationText: Double?
        var percent: Double?
        var position: Double?
        for (key, value) in object {
            let field = normalized(key)
            if duration == nil, durationText == nil, isDurationKey(field) {
                if let number = self.number(value) { duration = number }
                else if let text = value as? String { durationText = clockSeconds(text) }
            } else if percent == nil, isProgressKey(field) {
                if let number = self.number(value) { percent = number }
                else if let text = value as? String { percent = percentText(text) }
            } else if position == nil, isPositionKey(field), let number = self.number(value) {
                position = number
            }
        }
        guard duration != nil || durationText != nil || percent != nil else { return nil }
        let finished = object.contains { finishKeys.contains(normalized($0.key)) && ($0.value as? Bool) == true }
        return Lesson(name: name, identifier: identifierField(object) ?? "", durationRaw: duration,
                      durationText: durationText, percentRaw: percent, positionRaw: position, markedFinished: finished,
                      courseKey: matchingText(object, keys: courseIdKeys),
                      courseLabel: matchingText(object, keys: courseNameKeys))
    }

    /// Reads the first matching field as text, whether the site sent a number or a string.
    static func matchingText(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            for (candidate, value) in object where normalized(candidate) == key {
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    return number.stringValue
                }
                if let text = value as? String, !text.isEmpty, text.count <= 200, !text.contains("\n") { return text }
            }
        }
        return nil
    }

    /// Sites often format a duration for display instead of sending a number: "45:30", "01:02:03", "45分钟", "1小时20分".
    static func clockSeconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        let parts = trimmed.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 || parts.count == 3, parts.allSatisfy({ Double($0) != nil }) {
            let seconds = parts.compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
            return seconds > 0 ? seconds : nil
        }
        guard let pattern = unitPattern else { return nil }
        var total: Double = 0
        var found = false
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in pattern.matches(in: trimmed, options: [], range: range) {
            guard let amountRange = Range(match.range(at: 1), in: trimmed),
                  let unitRange = Range(match.range(at: 2), in: trimmed),
                  let amount = Double(trimmed[amountRange]), amount > 0 else { continue }
            let unit = trimmed[unitRange].lowercased()
            if unit.contains("小时") || unit.contains("时") || unit.hasPrefix("h") { total += amount * 3600 }
            else if unit.contains("分") || unit.hasPrefix("m") { total += amount * 60 }
            else { total += amount }
            found = true
        }
        guard found, total > 0 else { return nil }
        return total
    }

    static func percentText(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("%"), trimmed.count <= 16 else { return nil }
        return Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces))
    }

    static let unitPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*(小时|时|hours|hour|hrs|hr|h|分钟|分|minutes|minute|mins|min|m|秒钟|秒|seconds|second|secs|sec|s)",
        options: [.caseInsensitive])

    static func isDurationKey(_ field: String) -> Bool {
        durationKeys.contains(field) || field.hasSuffix("duration") || field.hasSuffix("seconds")
            || field.hasSuffix("length") || field.hasSuffix("shichang")
    }
    static func isProgressKey(_ field: String) -> Bool {
        progressKeys.contains(field) || field.hasSuffix("percent") || field.hasSuffix("progress") || field.hasSuffix("rate")
    }
    static func isPositionKey(_ field: String) -> Bool {
        field == "position" || field.hasSuffix("position") || field.hasSuffix("currenttime")
    }

    static func number(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let result = number.doubleValue
            return result.isFinite ? result : nil
        }
        if let text = value as? String {
            let result = Double(text.trimmingCharacters(in: .whitespaces))
            return (result?.isFinite ?? false) ? result : nil
        }
        return nil
    }
}
