import Foundation

public struct FixedEventTextDraft: Identifiable, Sendable {
    public let id: UUID
    public var event: FixedEvent
    public let warnings: [String]
    public let source: String

    init(event: FixedEvent, warnings: [String], source: String) {
        self.id = event.id
        self.event = event
        self.warnings = warnings
        self.source = source
    }
}

public struct FixedEventTextResult: Sendable {
    public var drafts: [FixedEventTextDraft] = []
    public var messages: [String] = []
}

/// Local, deliberately conservative extraction. Parsing never writes planner data.
public enum FixedEventTextParser {
    private static let number = "[0-9零〇一二两三四五六七八九十]{1,3}"
    private static let period = "凌晨|早上|早晨|上午|中午|下午|傍晚|晚上|晚间|晚"
    private static var clockPattern: String {
        "(?:(\(period))\\s*)?(?<![0-9])([0-9]{1,2})[:：]([0-9]{2})(?![0-9])|(?:(\(period))\\s*)?(\(number))\\s*[点时]\\s*(?:(半|一刻|三刻)|([0-9零〇一二两三四五六七八九十]{1,3})分?)?"
    }
    private static let datePattern = "(?<![0-9:])(?:(20[0-9]{2})[年/\\-])?([0-9]{1,2})[月/\\-]([0-9]{1,2})(?:日|号)?(?![0-9:])"
    private static let relativePattern = "大后天|后天|明天|今天|今日|明日|后日|(?:下下|下|本|这)?(?:周|星期|礼拜)[一二三四五六日天1-7]"

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> FixedEventTextResult {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return .init(messages: ["请先粘贴通知、聊天内容或日程描述。"] ) }
        guard source.count <= 30_000 else { return .init(messages: ["一次最多识别 30000 字，请分段粘贴。"] ) }
        let normalized = normalize(source)
        // Keep a complete notice together when it has just one time or time range.
        // Multiple notices are separated by a newline, semicolon or full stop.
        let separated = source.components(separatedBy: CharacterSet(charactersIn: "\n；;。"))
        let datedNotices = separated.filter {
            let text = normalize($0)
            return !matches(clockPattern, text).isEmpty && (!matches(datePattern, text).isEmpty || !matches(relativePattern, text).isEmpty || isRecurring(text))
        }.count
        let pieces = matches(clockPattern, normalized).count <= 2 && datedNotices < 2 ? [source] : separated
        var result = FixedEventTextResult()
        var dateContext = ""
        var rejected = 0
        for piece in pieces {
            let piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPiece = normalize(piece)
            guard !piece.isEmpty else { continue }
            let hasDate = !matches(datePattern, normalizedPiece).isEmpty || !matches(relativePattern, normalizedPiece).isEmpty || isRecurring(normalizedPiece)
            if hasDate {
                // Carry only date expressions, never a previous appointment's clock.
                dateContext = (matches(datePattern, normalizedPiece) + matches(relativePattern, normalizedPiece))
                    .sorted { $0.range.location < $1.range.location }
                    .map { capture($0, 0, normalizedPiece) }.joined(separator: " ")
                if isRecurring(normalizedPiece) {
                    dateContext = replacing(clockPattern, normalizedPiece, with: "")
                }
            }
            guard !matches(clockPattern, normalizedPiece).isEmpty else { continue }
            let context = hasDate || dateContext.isEmpty ? piece : dateContext + "\n" + piece
            switch parseNotice(context, now: now, calendar: calendar) {
            case .success(let draft):
                if !result.drafts.contains(where: { $0.event.title == draft.event.title && $0.event.startDate == draft.event.startDate && $0.event.startMinute == draft.event.startMinute && $0.event.endMinute == draft.event.endMinute && $0.event.weekdays == draft.event.weekdays && $0.event.endDate == draft.event.endDate }) {
                    result.drafts.append(draft)
                }
            case .failure(let error):
                rejected += 1
                if !result.messages.contains(error.message) { result.messages.append(error.message) }
            }
            if result.drafts.count == 20 {
                result.messages.append("最多展示 20 条候选，请核对后分批添加其余事项。")
                break
            }
        }
        if result.drafts.isEmpty && rejected == 0 { result.messages.append("未找到明确的日期和时间。请补充例如“明天 18:00 开会”或“每周三下午 3 点到 5 点上课”。") }
        if rejected > 0 && !result.drafts.isEmpty { result.messages.append("部分内容未能确定时间，已保留可识别的候选；请核对原文，避免遗漏。") }
        return result
    }

    private struct ParseError: Error { let message: String }
    private struct Clock {
        var minute: Int
        let period: String
        let range: NSRange
        let hour: Int
    }

    private static func parseNotice(_ source: String, now: Date, calendar: Calendar) -> Result<FixedEventTextDraft, ParseError> {
        let text = normalize(source)
        func fail(_ message: String) -> Result<FixedEventTextDraft, ParseError> { .failure(.init(message: message)) }
        if !matches("取消|改期|推迟|延期|(?:时间|日期|会议|活动)待定|暂不|另择|任选|之间|时段内|浮动", text).isEmpty {
            return fail("内容涉及取消、变更或浮动时段，请先整理明确的活动日期与起止时间，或手动添加。")
        }
        var warnings: [String] = []
        let today = calendar.startOfDay(for: now)
        let dateMatches = matches(datePattern, text)
        let relativeMatches = matches(relativePattern, text)
        var dates: [Date] = []
        var inferredYear: Int?
        for match in dateMatches {
            let yearText = capture(match, 1, text)
            var year = Int(yearText) ?? inferredYear ?? calendar.component(.year, from: today)
            guard let month = Int(capture(match, 2, text)), let day = Int(capture(match, 3, text)) else { continue }
            func makeDate(_ year: Int) -> Date? {
                guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)), calendar.component(.month, from: value) == month, calendar.component(.day, from: value) == day else { return nil }
                return calendar.startOfDay(for: value)
            }
            guard var date = makeDate(year) else { return fail("日期不存在，请核对原文中的月、日。") }
            if yearText.isEmpty {
                if let previous = dates.last, date < previous { year += 1 }
                else if dates.isEmpty && date < today { year += 1 }
                guard let adjusted = makeDate(year) else { return fail("无法确定日期年份，请填写完整年月日。") }
                date = adjusted
                warnings.append("原文未写年份，按 \(year) 年解释，请核对。")
            }
            inferredYear = year
            dates.append(date)
        }
        let recurring = isRecurring(text)
        let weekdays = recurring ? recurringWeekdays(text) : []
        if recurring && weekdays.isEmpty { return fail("重复星期不明确，请补充例如“每周一、三”或“每天”。") }
        let datePrefix = dateMatches.first.map { (text as NSString).substring(to: $0.range.location) } ?? ""
        let singleDateIsEnd = recurring && dates.count == 1 && !matches("(?:截止|截至|直到|至|到)\\s*$", datePrefix).isEmpty
        let start: Date
        if let date = dates.first, !singleDateIsEnd { start = date }
        else if let relative = relativeMatches.first {
            guard let value = relativeDate(capture(relative, 0, text), today: today, calendar: calendar) else { return fail("无法确定相对日期，请补充具体日期。") }
            start = value
        } else if recurring { start = today }
        else { return fail("找到了时间，但没有明确日期；请补充“今天”“明天”或具体月日。") }

        if dates.count > 1 && !recurring { return fail("同一段出现多个日期，请将每项日程分行粘贴后分别识别。") }
        if !recurring {
            for match in relativeMatches {
                let relative = capture(match, 0, text)
                let bareWeekday = relative.hasPrefix("周") || relative.hasPrefix("星期") || relative.hasPrefix("礼拜")
                if let implied = relativeDate(relative, today: today, calendar: calendar) {
                    let consistent = bareWeekday
                        ? calendar.component(.weekday, from: implied) == calendar.component(.weekday, from: start)
                        : calendar.isDate(implied, inSameDayAs: start)
                    if !consistent { return fail("同一段出现不一致的日期或星期，请核对或将每项日程分行粘贴。") }
                }
            }
        }
        var endDate = start
        if recurring {
            if dates.count > 2 { return fail("重复日程包含多组日期，请分段识别。") }
            if singleDateIsEnd { endDate = dates[0] }
            else if dates.count == 2 { endDate = dates[1] }
            else if let duration = matches("(?:持续|共|为期)\\s*([0-9一二三四五六七八九十]{1,3})\\s*周", text).first, let weeks = integer(capture(duration, 1, text)), (1...520).contains(weeks) {
                endDate = calendar.date(byAdding: .day, value: weeks * 7 - 1, to: start)!
            } else {
                endDate = calendar.date(byAdding: .day, value: 16 * 7 - 1, to: start)!
                warnings.append("未写重复截止日期，暂按持续 16 周预填，请核对。")
            }
            // Keep the interval's first date, even when the first occurrence is later.
            guard endDate >= start else { return fail("重复结束日期早于开始日期，请核对。") }
        }
        if start < today { warnings.append("识别日期已过去，请确认是否仍需添加。") }
        if recurring, endDate < today { warnings.append("重复日程的结束日期已过去，请修改日期。") }

        let timeMatches = matches(clockPattern, text)
        guard !timeMatches.isEmpty, timeMatches.count <= 2 else { return fail("同一段存在多组时间，请把每项日程分行，或只保留本次活动的起止时间。") }
        var clocks: [Clock] = []
        for match in timeMatches {
            let colon = !capture(match, 2, text).isEmpty
            let period = capture(match, colon ? 1 : 4, text)
            guard let hour = integer(capture(match, colon ? 2 : 5, text)), (0...24).contains(hour) else { return fail("小时超出范围，请核对时间。") }
            let suffix = capture(match, 6, text)
            let minute = colon ? Int(capture(match, 3, text)) : (suffix == "半" ? 30 : suffix == "一刻" ? 15 : suffix == "三刻" ? 45 : integer(capture(match, 7, text)) ?? 0)
            guard let minute, (0...59).contains(minute), hour < 24 || minute == 0 else { return fail("分钟超出范围，请核对时间。") }
            guard let converted = clockMinute(hour: hour, minute: minute, period: period) else { return fail("时段与小时不一致，请核对上午、下午或晚上。") }
            clocks.append(Clock(minute: converted, period: period, range: match.range, hour: hour))
        }
        var first = clocks[0]
        // A period immediately before the clock is already consumed by the pattern.
        if first.period.isEmpty && first.hour > 0 && first.hour < 12 { warnings.append("原文未说明上午或下午，按 24 小时制解释，请核对。") }
        var endMinute: Int
        if clocks.count == 2 {
            var second = clocks[1]
            let between = (text as NSString).substring(with: NSRange(location: first.range.location + first.range.length, length: second.range.location - first.range.location - first.range.length))
            guard !matches("^\\s*(?:到|至|[-~—–～])\\s*$", between).isEmpty else { return fail("两处时间不是明确的起止区间，请只保留活动时间，或用“到”连接。") }
            if second.period.isEmpty && !first.period.isEmpty && second.hour < 12 {
                second.minute = clockMinute(hour: second.hour, minute: second.minute % 60, period: first.period) ?? second.minute
            } else if first.period.isEmpty && !second.period.isEmpty && first.hour < 12 {
                first.minute = clockMinute(hour: first.hour, minute: first.minute % 60, period: second.period) ?? first.minute
            }
            endMinute = second.minute
        } else {
            let durationPattern = "(?:持续|时长|共|约|用时)\\s*(\(number))\\s*(个半小时|小时半|个小时|小时|分钟|分)(?:\\s*(\(number))\\s*分(?:钟)?)?"
            if let duration = matches(durationPattern, text).first, let amount = integer(capture(duration, 1, text)) {
                let unit = capture(duration, 2, text)
                let minutes = unit.contains("小时") ? amount * 60 + (unit.contains("半") ? 30 : 0) + (integer(capture(duration, 3, text)) ?? 0) : amount
                guard minutes > 0 else { return fail("活动时长必须大于 0，请核对。") }
                endMinute = first.minute + minutes
            } else {
                endMinute = min(first.minute + 60, 1440)
                warnings.append("未写结束时间，暂按 \(endMinute - first.minute) 分钟预填，保存前请核对。")
            }
        }
        guard first.minute < endMinute, first.minute < 1440, endMinute <= 1440 else { return fail("结束时间须晚于开始时间；跨午夜活动请拆成两条事项。") }
        let title = extractTitle(text)
        if title == "待命名事项" { warnings.append("未确定事项名称，请在编辑页补充。") }
        var event = FixedEvent(title: title, startMinute: first.minute, endMinute: endMinute, startDate: start, endDate: endDate, weekdays: weekdays)
        event.notes = source
        return .success(.init(event: event, warnings: Array(Set(warnings)).sorted(), source: source))
    }

    private static func isRecurring(_ text: String) -> Bool {
        !matches("每天|每日|每周|每星期|每礼拜|每逢|工作日|周末", text).isEmpty
    }
    private static func recurringWeekdays(_ text: String) -> Set<Int> {
        if text.contains("每天") || text.contains("每日") { return Set(1...7) }
        if text.contains("工作日") { return Set(2...6) }
        if text.contains("周末") { return [1, 7] }
        let values: [String: Int] = ["一":2,"二":3,"三":4,"四":5,"五":6,"六":7,"日":1,"天":1,"1":2,"2":3,"3":4,"4":5,"5":6,"6":7,"7":1]
        var result: Set<Int> = []
        for match in matches("(?:每(?:周|星期|礼拜)|每逢|周|星期|礼拜)([一二三四五六日天1-7](?:\\s*(?:、|,|，|和|及|到|至|[-~—～])\\s*(?:(?:每)?(?:周|星期|礼拜))?[一二三四五六日天1-7])*)", text) {
            let list = capture(match, 1, text)
            let days = matches("[一二三四五六日天1-7]", list).compactMap { values[capture($0, 0, list)] }
            if !matches("到|至|[-~—～]", list).isEmpty && days.count == 2 {
                var day = days[0]
                for _ in 0..<7 { result.insert(day); if day == days[1] { break }; day = day % 7 + 1 }
            } else { result.formUnion(days) }
        }
        return result
    }
    private static func relativeDate(_ expression: String, today: Date, calendar: Calendar) -> Date? {
        let offsets = ["今天":0,"今日":0,"明天":1,"明日":1,"后天":2,"后日":2,"大后天":3]
        if let offset = offsets[expression] { return calendar.date(byAdding: .day, value: offset, to: today) }
        let values: [Character: Int] = ["一":0,"二":1,"三":2,"四":3,"五":4,"六":5,"日":6,"天":6,"1":0,"2":1,"3":2,"4":3,"5":4,"6":5,"7":6]
        guard let last = expression.last, let target = values[last] else { return nil }
        let current = (calendar.component(.weekday, from: today) + 5) % 7
        var delta = target - current
        if expression.hasPrefix("下下") { delta += 14 }
        else if expression.hasPrefix("下") { delta += 7 }
        else if !expression.hasPrefix("本") && !expression.hasPrefix("这") && delta < 0 { delta += 7 }
        return calendar.date(byAdding: .day, value: delta, to: today)
    }
    private static func clockMinute(hour: Int, minute: Int, period: String) -> Int? {
        if period.isEmpty { return hour * 60 + minute }
        if hour > 12 {
            if ["凌晨", "早上", "早晨", "上午", "中午"].contains(period) { return nil }
            return hour * 60 + minute
        }
        if hour == 12 && ["晚上", "晚间", "晚"].contains(period) { return nil }
        if ["下午", "傍晚", "晚上", "晚间", "晚"].contains(period) { return (hour == 12 ? 12 : hour + 12) * 60 + minute }
        if period == "中午" { return (hour < 11 ? hour + 12 : hour) * 60 + minute }
        return (hour == 12 && period == "凌晨" ? 0 : hour) * 60 + minute
    }
    private static func extractTitle(_ text: String) -> String {
        if let match = matches("(?:事项|主题|活动名称|会议名称|名称)[：:]\\s*([^\\n，,。；;]{2,60})", text).first {
            return capture(match, 1, text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let match = matches("(?:召开|举行|开展|举办)\\s*([^\\n，,。；;]{2,60})", text).first {
            return capture(match, 1, text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var value = text
        for pattern in [datePattern, relativePattern, clockPattern, "(?:每天|每日|每周|每星期|每礼拜|工作日|周末)(?:[一二三四五六日天1-7、，,到至和及\\- ]*)", "(?:持续|时长|共|约|用时)\\s*\(number)\\s*(?:小时|分钟|分|周)", "[到至~—～]", "@所有人"] {
            value = replacing(pattern, value, with: " ")
        }
        let chunks = value.components(separatedBy: CharacterSet(charactersIn: "\n，,。；;"))
        let title = chunks.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:、- "))) }.first { !$0.isEmpty && !["时间", "日期", "通知", "地点另行通知"].contains($0) } ?? "待命名事项"
        return String(title.prefix(60))
    }
    private static func integer(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        if value == "十" { return 10 }
        if let index = value.firstIndex(of: "十") {
            let left = String(value[..<index]), right = String(value[value.index(after: index)...])
            guard let tens = left.isEmpty ? 1 : left.first.flatMap({ digits[$0] }), let ones = right.isEmpty ? 0 : right.first.flatMap({ digits[$0] }) else { return nil }
            return tens * 10 + ones
        }
        return value.count == 1 ? value.first.flatMap { digits[$0] } : nil
    }
    private static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if (0xFF01...0xFF5E).contains(scalar.value) { return UnicodeScalar(scalar.value - 0xFEE0)! }
            return scalar.value == 0x3000 ? UnicodeScalar(0x20)! : scalar
        }))
    }
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func capture(_ match: NSTextCheckingResult, _ group: Int, _ text: String) -> String {
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return "" }
        return String(text[range])
    }
    private static func replacing(_ pattern: String, _ text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
