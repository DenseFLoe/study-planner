import Foundation

/// Keeps a user's order stable when a website refresh adds or removes lessons.
public enum LessonOrdering {
    public static func intelligentIDs(_ lessons: [WebCourseLesson]) -> [String] {
        intelligent(lessons.map {
            LessonWorkItem(id: $0.id, name: $0.name, subject: $0.subject, stage: $0.stage,
                           chapter: $0.chapter, durationMinutes: 0, remainingMinutes: 0)
        }).map(\.id)
    }
    /// Build independent keys before comparing: pair-dependent heuristics can break sort transitivity.
    public static func intelligent(_ items: [LessonWorkItem]) -> [LessonWorkItem] {
        var cache: [String: SortKey] = [:]
        func key(_ value: String) -> SortKey {
            if let existing = cache[value] { return existing }
            let result = SortKey(value)
            cache[value] = result
            return result
        }
        let keyed = items.map { item in
            (item: item, keys: [item.subject, item.stage, item.chapter, item.name].map(key))
        }
        return keyed.sorted { lhs, rhs in
            for (a, b) in zip(lhs.keys, rhs.keys) {
                let comparison = a.compare(b)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.item.id < rhs.item.id
        }.map(\.item)
    }

    private struct SortKey {
        // These immutable expressions are shared across courses and projections.
        // Recompiling them for every field made a merged course expensive to display.
        private static let extensionPattern = try! NSRegularExpression(pattern: #"\.(mp4|mkv|mov|avi|flv|webm|m4v|ts|mp3|pdf)$"#)
        private static let videoPattern = try! NSRegularExpression(pattern: #"(?<![0-9])(?:2160|1440|1080|720|480)[pi]|[248]k|[hx]26[45]|\d+fps"#)
        private static let chinesePattern = try! NSRegularExpression(pattern: #"第?([零〇一二三四五六七八九十百两]+)([章节讲课集部分])"#)
        private static let partPatterns = ["上", "中", "下"].map {
            try! NSRegularExpression(pattern: "[（(【\\[]" + $0 + "[）)】\\]]|" + $0 + "[篇部集]$")
        }
        private static let countersPattern = try! NSRegularExpression(pattern: #"第\s*([0-9]+)\s*[章节讲课集]"#)
        private static let digitsPattern = try! NSRegularExpression(pattern: #"[0-9]+"#)
        private static let textPattern = try! NSRegularExpression(pattern: #"[0-9]+|[\s._\-—、()\[\]]"#)

        private static func stripping(_ pattern: NSRegularExpression, from value: String) -> String {
            pattern.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
        }
        let numbers: [String]
        let text: String
        let part: Int

        init(_ raw: String) {
            var value = raw.precomposedStringWithCompatibilityMapping.lowercased()
            value = Self.stripping(Self.extensionPattern, from: value)
            value = Self.stripping(Self.videoPattern, from: value)
            // Chinese counters become numeric counters without interpreting numerals in topic words
            // such as “一元函数” or “二次型” as lesson numbers.
            do {
                let matches = Self.chinesePattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
                for match in matches.reversed() {
                    guard let range = Range(match.range(at: 1), in: value) else { continue }
                    value.replaceSubrange(range, with: String(Self.chineseNumber(String(value[range]))))
                }
            }
            var part = 0
            for (index, pattern) in Self.partPatterns.enumerated() {
                if let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                   let range = Range(match.range, in: value) {
                    part = index + 1; value.removeSubrange(range); break
                }
            }
            self.part = part
            self.text = Self.withoutNumbers(value)
            let explicit = Self.countersPattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
            var ranges = explicit.map { $0.range(at: 1) }
            let tailStart = explicit.last.map { NSMaxRange($0.range) } ?? 0
            let tail = NSRange(location: tailStart, length: (value as NSString).length - tailStart)
            ranges += Self.digitsPattern.matches(in: value, range: tail).map(\.range)
            self.numbers = ranges.compactMap {
                guard let range = Range($0, in: value) else { return nil }
                let digits = value[range].drop(while: { $0 == "0" })
                return digits.isEmpty ? "0" : String(digits)
            }
        }

        func compare(_ other: SortKey) -> ComparisonResult {
            for (a, b) in zip(numbers, other.numbers) where a != b {
                if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
                return a < b ? .orderedAscending : .orderedDescending
            }
            if numbers.count != other.numbers.count {
                return numbers.count < other.numbers.count ? .orderedAscending : .orderedDescending
            }
            // Compare title text before “上/中/下”, so unrelated unnumbered topics stay together.
            let title = NetdiskTitles.naturalCompare(text, other.text)
            if title != .orderedSame { return title }
            if part != other.part { return part < other.part ? .orderedAscending : .orderedDescending }
            return .orderedSame
        }

        private static func withoutNumbers(_ text: String) -> String {
            stripping(textPattern, from: text)
        }

        private static func chineseNumber(_ text: String) -> Int {
            let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                           "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
            var total = 0, pending = 0
            for character in text {
                if let digit = digits[character] { pending = digit }
                else { total += max(1, pending) * (character == "百" ? 100 : 10); pending = 0 }
            }
            return total + pending
        }
    }

    public static func resolved(ids: [String], preferred: [String]?) -> [String] {
        let known = Set(ids)
        var seen = Set<String>()
        return ((preferred ?? []).filter { known.contains($0) && seen.insert($0).inserted }
                + ids.filter { seen.insert($0).inserted })
    }

    /// `before` is a zero-based position in the original list; `order.count` means the end.
    public static func move(_ order: [String], selected: Set<String>, before destination: Int) -> [String] {
        guard !selected.isEmpty, (0...order.count).contains(destination) else { return order }
        let moving = order.filter { selected.contains($0) }
        let remaining = order.filter { !selected.contains($0) }
        let removedBefore = order.prefix(destination).filter { selected.contains($0) }.count
        let insertAt = min(remaining.count, destination - removedBefore)
        return Array(remaining.prefix(insertAt)) + moving + Array(remaining.dropFirst(insertAt))
    }
}
