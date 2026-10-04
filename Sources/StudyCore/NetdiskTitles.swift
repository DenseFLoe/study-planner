import Foundation

/// Name handling for netdisk files: canonicalisation, episode extraction, natural ordering,
/// and the fuzzy comparison the duplicate detector is built on.
public enum NetdiskTitles {
    public struct Parsed: Equatable, Sendable {
        /// Name with the extension, copy markers, episode prefixes and release noise removed.
        public var base: String
        /// Release tokens that still distinguish two encodes, e.g. `1080p` or `水印`, lowercased.
        public var variant: String
        public var episode: Int?
        /// The `(1)` in `第3讲 (1).mp4`: the provider's marker for a second copy of one file.
        public var copyIndex: Int?
        init(base: String, variant: String, episode: Int?, copyIndex: Int?) {
            self.base = base; self.variant = variant; self.episode = episode; self.copyIndex = copyIndex
        }
    }

    /// Resolution tiers, lowest first; used to keep the best copy of a duplicate.
    public static let resolutionTiers: [(pattern: String, rank: Int)] = [
        ("8k", 5), ("4k", 4), ("2160", 4), ("2k", 3), ("1440", 3),
        ("1080", 2), ("720", 1), ("540", 1), ("480", 0), ("360", 0)
    ]

    private static let noiseWords: Set<String> = [
        "hevc", "h264", "h265", "avc", "x264", "x265", "av1", "vp9", "10bit", "8bit",
        "aac", "flac", "mp3", "opus", "ac3",
        "video", "音频", "高清", "超清", "标清", "流畅", "完整版", "全集", "无水印", "水印",
        "ocr", "1v1", "官方", "首发", "更新", "新版", "旧版", "修订", "修正", "重制",
        "中字", "中文", "国语", "双语", "字幕", "带字幕", "内嵌", "外挂", "课程", "讲义"
    ]
    /// These must match a whole token: `1080p` is noise, `极限 1080p 无水印` is not.
    private static let noisePatterns: [String] = [
        #"^\d{3,4}\s*[pPiI]$"#,
        #"^(?:hd|fhd|uhd|sd|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip)$"#,
        #"^x\s?26[45]$"#,
        #"^h\s?26[45]$"#,
        #"^\d{1,3}\s?(?:fps|kbps|mbps)$"#
    ]
    private static let copyMarker = #"^\((?:\d{1,2}|[a-zA-Z]|副本|copy|复件)\)$"#
    private static let separators = #"[\s\-_.,;:+、·]*"#
    /// Leading decoration: separators plus optional brace/paren numbering or a short numeric label.
    private static let leadingDecoration = #"[\s\-_.,;:+、·]*(?:\{\s*\d{1,3}\s*\}|[（(【\[]\s*\d{1,3}\s*[）)】\]]|\d{1,4}(?=[\s\-_.,;:+、·,)])\s*[-_.、,)]?)?[\s\-_.,;:+、·]*"#

    /// Episode markers written in front of the title. The capture holds the number.
    private static let leadingNumeric: [(pattern: String, group: Int)] = [
        (#"[\s\-_.,;:+、·]*\{\s*(\d{1,3})\s*\}"# + separators, 1),
        (#"[\s\-_.,;:+、·]*[（(【\[]\s*(\d{1,3})\s*[）)】\]]"# + separators, 1),
        (#"[\s\-_.,;:+、·]*(\d{1,4})\s*[-_.、,)]\s*"#, 1),
        (#"[\s\-_.,;:+、·]*(\d{1,4})\s*[-—~]\s*\d{1,3}(?![0-9pPiI])"#, 1),
        (#"[\s\-_.,;:+、·]*(\d{1,4})(?=\s)"#, 1),
        (#"[\s\-_.,;:+、·]*(\d{1,4})$"#, 1)
    ]
    /// A whitespace escape that survives a raw string literal.
    private static let space = #"\s"#
    private static let leadingCounter = #"[\s\-_.,;:+、·]*第"# + space
        + #"*([0-9０-９一二三四五六七八九十百零〇两]{1,4})"# + space + #"*[讲课节集次]"# + separators
    private static let leadingChapter = #"[\s\-_.,;:+、·]*第"# + space
        + #"*(\d{1,4})"# + space + #"*[章部分]"# + separators
    /// Numbers that merely decorate a name, e.g. `高数12-3定制伴学`.
    private static let inlineNumbers = [#"(?<!\d)(\d{1,4})\s*[-—~]\s*\d{1,3}(?!\d)"#,
                                        #"(?:^|[\s._\-])(\d{1,4})(?=[\s._\-])"#,
                                        #"(?:^|[\s._\-])(\d{1,4})$"#]

    // MARK: - Small helpers

    private static func folded(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x3000: out.append(Unicode.Scalar(0x20)!)
            case 0xFF01...0xFF5E: out.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0x2010...0x2015, 0x2212: out.append(Unicode.Scalar(0x2D)!)
            case 0x2018, 0x2019, 0x2032: out.append(Unicode.Scalar(0x27)!)
            case 0x201C, 0x201D, 0x2033: out.append(Unicode.Scalar(0x22)!)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
    private static func matches(_ value: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
    /// Matches only at position 0, verified by location.
    ///
    /// These patterns deliberately avoid a `^` anchor: this regex engine fails to match an anchored
    /// pattern whose first literal is a CJK character (`^第\s*(\d)` never matches `第10讲`), while the
    /// same pattern unanchored matches fine. Checking the location is both correct and portable.
    private static func firstMatch(_ value: String, _ pattern: String, group: Int) -> (text: String, number: Int?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.range.location == 0,
              let whole = Range(match.range, in: value) else { return nil }
        var number: Int?
        if match.numberOfRanges > group, let captured = Range(match.range(at: group), in: value) {
            let digits = String(value[captured]).filter { $0.isNumber || $0.isLetter }
            number = Int(digits) ?? chineseNumber(digits)
        }
        return (String(value[whole]), number)
    }
    /// The same as `firstMatch`, but at any position; used to read a number out of a name.
    private static func anyMatch(_ value: String, _ pattern: String, group: Int) -> (text: String, number: Int?)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let whole = Range(match.range, in: value) else { return nil }
        var number: Int?
        if match.numberOfRanges > group, let captured = Range(match.range(at: group), in: value) {
            let digits = String(value[captured]).filter { $0.isNumber || $0.isLetter }
            number = Int(digits) ?? chineseNumber(digits)
        }
        return (String(value[whole]), number)
    }
    private static func collapsed(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isNumber || $0 == "." }
    }
    private static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var value = 0
        var pending = 0
        var seen = false
        for character in text {
            if let digit = digits[character] { pending = digit; seen = true; continue }
            switch character {
            case "十": value += (pending == 0 ? 1 : pending) * 10; pending = 0; seen = true
            case "百": value += (pending == 0 ? 1 : pending) * 100; pending = 0; seen = true
            default: return nil
            }
        }
        guard seen else { return nil }
        return value + pending
    }
    private static func droppingExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return name }
        let suffix = name[name.index(after: dot)...]
        guard !suffix.isEmpty, suffix.count <= 5, suffix.allSatisfy({ $0.isLetter || $0.isNumber }) else { return name }
        return String(name[..<dot])
    }
    private static func isCopyMarker(_ token: String) -> Bool { !matches(token, copyMarker).isEmpty }
    /// A token that carries no title information: a quality tag, a codec, or a bare number.
    private static func isNoiseToken(_ token: String) -> Bool {
        let lowered = token.lowercased()
        if noiseWords.contains(lowered) { return true }
        if isNumeric(token), token.count <= 4 { return true }
        return noisePatterns.contains { !matches(lowered, $0).isEmpty }
    }
    /// `高数强化 1080p 无水印` and `高数强化 1080p 无水印 完整版` are the same lesson.
    private static func withoutNoise(_ value: String) -> String {
        collapsed(value.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !isNoiseToken($0) }
            .joined(separator: " "))
    }

    // MARK: - Public API

    /// The episode number a file claims, if it claims one. An explicit counter (`第3讲`) beats a
    /// decorative brace number (`{11}`), which is only a position label.
    public static func episode(in name: String) -> Int? {
        let value = folded(droppingExtension(name))
        // The counter may follow a label the provider prepends, e.g. `{11}--第10讲`.
        if let found = anyMatch(value, leadingCounter, group: 1), let number = found.number,
           number > 0, number <= 9999 { return number }
        for entry in leadingNumeric {
            if let found = firstMatch(value, entry.pattern, group: entry.group), let number = found.number,
               number > 0, number <= 9999 { return number }
        }
        for pattern in inlineNumbers {
            if let found = anyMatch(value, pattern, group: 1), let number = found.number,
               number > 0, number <= 9999 { return number }
        }
        return nil
    }

    public static func resolutionRank(_ name: String) -> Int {
        let value = folded(name).lowercased()
        var rank = 0
        for tier in resolutionTiers where value.contains(tier.pattern) { rank = max(rank, tier.rank) }
        return rank
    }

    /// Base name, variant tokens and episode for a file or folder name.
    public static func parse(_ rawName: String) -> Parsed {
        let name = folded(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = droppingExtension(name)
        var parts: [String] = []
        var variants: [String] = []
        var copyIndex: Int?
        var buffer = ""

        func flush() {
            let token = collapsed(buffer).trimmingCharacters(in: .whitespaces)
            buffer = ""
            guard !token.isEmpty else { return }
            let lowered = token.lowercased()
            let isNoise = noiseWords.contains(lowered)
                || (isNumeric(token) && token.count <= 2)
                || noisePatterns.contains(where: { !matches(token, $0).isEmpty })
            if isNoise { variants.append(lowered); return }
            parts.append(token)
        }

        var index = stem.startIndex
        let end = stem.endIndex
        while index < end {
            let character = stem[index]
            switch character {
            case "(", "（", "[", "【", "{":
                flush()
                let closers: [Character] = character == "(" || character == "（" ? [")", "）"]
                    : (character == "[" ? ["]"] : (character == "【" ? ["】"] : ["}"]))
                var inner = ""
                var cursor = stem.index(after: index)
                while cursor < end, !closers.contains(stem[cursor]) {
                    inner.append(stem[cursor]); cursor = stem.index(after: cursor)
                }
                let token = collapsed(inner).trimmingCharacters(in: .whitespaces)
                let lowered = token.lowercased()
                if isCopyMarker("(" + token + ")") {
                    // `(1)` means "another copy of the same file", so it is not a release variant.
                    if let number = Int(token.filter { $0.isNumber }), copyIndex == nil {
                        copyIndex = number
                    } else if copyIndex == nil {
                        copyIndex = 0
                    }
                } else {
                    let isNoise = noiseWords.contains(lowered) || isNumeric(token)
                        || noisePatterns.contains(where: { !matches(token, $0).isEmpty })
                    if isNoise {
                        if !token.isEmpty { variants.append(lowered) }
                    } else if !token.isEmpty {
                        parts.append(token)
                    }
                }
                index = cursor < end ? stem.index(after: cursor) : end
                continue
            case ")", "）", "]", "】", "}":
                flush()
            default:
                buffer.append(character)
            }
            index = stem.index(after: index)
        }
        flush()

        let joined = collapsed(parts.joined(separator: " "))
        // The episode number belongs to `episode`, never to the name stem, so `第3讲 高数` and
        // `第10讲 高数` compare as the same lesson. A chapter label stays, because it names the
        // chapter: `第10章 重积分` is still about 重积分.
        var stripped = joined
        var marker: Int?
        // Same precedence as `episode(in:)`: an explicit counter wins, brace labels do not.
        if let found = firstMatch(joined, leadingCounter, group: 1) {
            let remainder = String(joined.dropFirst(found.text.count))
            if !remainder.isEmpty { stripped = remainder; marker = found.number }
        }
        if marker == nil {
            for entry in leadingNumeric {
                guard let found = firstMatch(joined, entry.pattern, group: entry.group) else { continue }
                let remainder = String(joined.dropFirst(found.text.count))
                guard !remainder.isEmpty else { continue }
                stripped = remainder; marker = found.number
                break
            }
        }
        if let found = firstMatch(stripped, leadingChapter, group: 1) {
            let remainder = String(stripped.dropFirst(found.text.count))
            if !remainder.isEmpty, let number = found.number, number > 0, number <= 9999 {
                if marker == nil { marker = number }
                stripped = remainder
            }
        }
        // Anything decorative still in front — braces, separators, a bare label — is not a name.
        if let decoration = matches(stripped, leadingDecoration).first, !decoration.isEmpty,
           !String(stripped.dropFirst(decoration.count)).isEmpty {
            stripped = String(stripped.dropFirst(decoration.count))
        }
        let base = withoutNoise(collapsed(stripped)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,;:+*/（）()【】[]")))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_.,;:+*/（）()【】[]"))
            .lowercased()
        return Parsed(base: base, variant: variants.joined(separator: " "),
                      episode: episode(in: stem) ?? marker, copyIndex: copyIndex)
    }

    /// Identity used to decide whether two files are the same lesson.
    public static func identity(_ rawName: String) -> String {
        let parsed = parse(rawName)
        let episode = parsed.episode.map { String(format: "%04d", min($0, 9999)) } ?? "----"
        return parsed.base + "|" + episode + "|" + parsed.variant
    }

    /// Identity that ignores release noise, so `第3讲` and `第3讲 1080p` still line up.
    public static func looseIdentity(_ rawName: String) -> String {
        let parsed = parse(rawName)
        let episode = parsed.episode.map { String(format: "%04d", min($0, 9999)) } ?? ""
        return parsed.base + "|" + episode
    }

    /// True for an ASCII digit only. CJK numerals such as `一` also answer `isNumber`, so a
    /// run like `4一阶` would otherwise be parsed as `Int("4一") == nil` and collapse to 0,
    /// placing `7.4` before `7.1`. Fullwidth digits are already folded to ASCII above.
    private static func isDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }

    /// Numeric-aware ordering: `第2讲` sorts before `第10讲`, and `3-2` before `3-10`.
    public static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = folded(lhs).lowercased(), right = folded(rhs).lowercased()
        var a = left.startIndex, b = right.startIndex
        while a < left.endIndex, b < right.endIndex {
            let ca = left[a], cb = right[b]
            if isDigit(ca), isDigit(cb) {
                var na = "", nb = ""
                var ai = a, bi = b
                while ai < left.endIndex, isDigit(left[ai]) { na.append(left[ai]); ai = left.index(after: ai) }
                while bi < right.endIndex, isDigit(right[bi]) { nb.append(right[bi]); bi = right.index(after: bi) }
                let va = Int(na) ?? 0, vb = Int(nb) ?? 0
                if va != vb { return va < vb ? .orderedAscending : .orderedDescending }
                if na.count != nb.count { return na.count < nb.count ? .orderedAscending : .orderedDescending }
                a = ai; b = bi
                continue
            }
            if ca != cb { return ca < cb ? .orderedAscending : .orderedDescending }
            a = left.index(after: a); b = right.index(after: b)
        }
        if a == left.endIndex, b == right.endIndex { return .orderedSame }
        return a == left.endIndex ? .orderedAscending : .orderedDescending
    }

    /// Levenshtein distance with an early exit, so long file names stay cheap.
    public static func editDistance(_ lhs: String, _ rhs: String, limit: Int = 64) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 0 ... 1 similarity of two names, after canonicalisation.
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = parse(lhs).base, b = parse(rhs).base
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let distance = editDistance(a, b, limit: 64)
        let longest = max(a.count, b.count)
        guard distance <= 64, longest > 0 else { return 0 }
        return max(0, 1 - Double(distance) / Double(longest))
    }

    /// Share titles often carry a decorative wrapper; strip it before showing or comparing.
    public static func displayName(_ rawName: String) -> String {
        var value = collapsed(folded(rawName)).trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in [#"^[\s\-_=*·•]+"#, #"[\s\-_=*·•]+$"#] {
            while true {
                let found = matches(value, pattern)
                guard let match = found.first, !match.isEmpty else { break }
                value = pattern.hasPrefix("^") ? String(value.dropFirst(match.count)) : String(value.dropLast(match.count))
            }
        }
        return value
    }
}
