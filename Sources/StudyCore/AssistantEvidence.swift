import Foundation

/// Only the builder assigns IDs. User-provided labels are separate data, never fact statements.
public struct AssistantFact: Equatable, Sendable {
    public let id: String
    public let statement: String
    public let userText: [String: String]

    fileprivate var rendered: String {
        var fields = ["fact": statement]
        for (key, value) in userText { fields["untrusted_" + key] = value }
        return "[\(id)] \(Self.escapedJSON(fields))"
    }

    fileprivate static func escapedJSON(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        // JSON escapes quotes, backslashes and ASCII controls. Also escape reference delimiters,
        // Unicode line separators and invisible format characters (including bidi overrides).
        return String(decoding: data, as: UTF8.self).unicodeScalars.map { scalar -> String in
            if scalar == "[" || scalar == "]" || CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) || scalar.properties.generalCategory == .format {
                return scalar.utf16.map { String(format: "\\u%04X", $0) }.joined()
            }
            return String(scalar)
        }.joined()
    }
}

/// An allowlisted, read-only view of a snapshot. Never encode PlannerState for an API.
public struct AssistantEvidence: Equatable, Sendable {
    public let facts: [AssistantFact]
    public let capturedAt: Date
    public let courseAliases: [String]
    public var text: String { facts.map(\.rendered).joined(separator: "\n") }
    public var factCount: Int { facts.count }

    public func citationWarning(in answer: String) -> String? {
        let expression = try! NSRegularExpression(pattern: #"\[E([0-9]+)\]"#)
        let text = answer as NSString
        let matches = expression.matches(in: answer, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return "回答没有引用证据编号，请对照快照核验，不能视为已确认结论。" }
        let identifiers = Set(facts.map(\.id))
        if matches.contains(where: { !identifiers.contains("E" + text.substring(with: $0.range(at: 1))) }) {
            return "回答引用了本次快照不存在的证据编号，请勿采信这些引用。"
        }
        return nil
    }

    public static func build(state: PlannerState, day: Date, courseID: UUID? = nil,
                             includeNames: Bool = false, now: Date = Date(),
                             calendar: Calendar = .current, result: ScheduleResult? = nil,
                             dailyWarningMinutes: Int = 480) -> Self {
        let date = DateFormatter()
        date.calendar = calendar; date.timeZone = calendar.timeZone
        date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd HH:mm"
        func stamp(_ value: Date) -> String { date.string(from: value) }
        func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
        let scope = AssistantCourseScope(state: state, courseID: courseID)
        let courses = scope.courses, aliases = scope.aliases, selected = scope.selected
        let ids = Set(selected.map(\.id))
        var facts: [AssistantFact] = []
        func add(_ text: String, userText: [String: String] = [:]) {
            facts.append(.init(id: "E\(facts.count + 1)", statement: text, userText: userText))
        }
        add("快照时间 \(stamp(now))；时区 \(calendar.timeZone.identifier)；查看日期 \(stamp(calendar.startOfDay(for: day)))。以下为已保存数据的本地计算，不是历史排课决策轨迹。")
        add("范围：\(courseID == nil ? "当前课程概览" : "所选课程")；包含 \(selected.count)/\(courses.count) 门未归档课程。概览最多列12门；未列出的课程并非不存在。")
        if courseID != nil && selected.isEmpty { add("所选课程已删除或归档，没有可用课程信息。") }
        add("代码规则：开始日、截止日、可用时段、整节课顺序和课间15分钟休息优先满足；每日加量和均摊是偏好，不是每门课每日硬上限。启发式搜索有预算，未排入不等于已证明无解。")
        add("保存的偏好顺序：" + state.settings.schedulePriorities.orderedRules.map(\.title).joined(separator: " → ") + "；默认最小学习块 \(state.settings.minimumScheduleUnit) 分钟，最终余量允许更短。")
        add("每日总学习负担提醒线：\(max(30, dailyWarningMinutes))分钟；用于全日全部课程的提醒，不是单门课的排程硬上限。")
        if let result {
            if result.adjustments.isEmpty {
                add("本次评估没有提供调整记录，不能据此断言历史上未发生回退或调整。")
            }
            for adjustment in result.adjustments.prefix(8) {
                if let explanation = ScheduleExplanation.recordedAdjustment(adjustment) {
                    add("本次评估已记录的调整（全局）：\(explanation) 仅对应传入的本次评估，不是已保存课表的完整历史。")
                } else {
                    add("本次评估包含无法识别的调整记录，未导出其原文；无法据此解释具体原因。")
                }
            }
            if result.adjustments.count > 8 { add("另有\(result.adjustments.count - 8)条调整记录未列出。") }
        } else {
            add("未提供当前排程评估，无法确认本次计算的回退、调整或约束证明。")
        }
        if let plan = result?.dayPlans.first(where: { calendar.isDate($0.date, inSameDayAs: day) }) {
            add("当前界面评估的全日学习安排\(plan.plannedMinutes)分钟，可安排容量\(plan.availableMinutes)分钟；超过负担提醒线\(max(0, plan.plannedMinutes - max(30, dailyWarningMinutes)))分钟。此评估基于当前条件，不代表历史条件。")
        }
        let weekday = calendar.component(.weekday, from: day)
        let windows = state.settings.availability.filter { $0.weekday == weekday }
        add("所选日期可用时段：" + (windows.isEmpty ? "无" : windows.prefix(16).map { "\(clock($0.startMinute))–\(clock($0.endMinute))" }.joined(separator: "、")) + "（共\(windows.count)段，最多列16段；未扣除事项与休息）。")
        if let actual = state.settings.actualStudyStart(on: day, calendar: calendar) { add("保存的当日实际开始时间：\(stamp(actual))。") }
        let events = state.fixedEvents.filter { $0.occurs(on: day, calendar: calendar) }
        for (index, event) in events.prefix(16).enumerated() {
            add("事项\(index + 1)：\(clock(event.startMinute))–\(clock(event.endMinute))；\(event.isFloating ? "窗口内浮动占用" : "固定占用") \(event.occupiedMinutes) 分钟。")
        }
        if events.count > 16 { add("另有\(events.count - 16)项事项未列出；不能把以上时段视为全部约束。") }
        for course in selected {
            let alias = aliases[course.id]!
            let remaining = state.remainingMinutes(for: course)
            let pending = state.tasks.filter { $0.courseID == course.id && $0.isUnconfirmed && $0.planningEnd > now }
            let booked = pending.reduce(0) { $0 + $1.durationMinutes }
            let inDeadline = pending.filter { calendar.startOfDay(for: $0.start) <= calendar.startOfDay(for: course.deadline) }.reduce(0) { $0 + $1.durationMinutes }
            let start = max(calendar.startOfDay(for: now), calendar.startOfDay(for: course.startDate))
            let days = max(0, (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: course.deadline)).day ?? -1) + 1)
            add("\(alias)：总量\(course.totalMinutes)分钟；有效完成\(state.completedMinutes(for: course))分钟（含基础/来源进度并按现有去重规则折算）；剩余\(remaining)分钟。开始\(stamp(course.startDate))，截止\(stamp(course.deadline))（含当天）；优先级\(course.priority)，每日倍率\(course.dailyWeight)，自动排程\(course.autoScheduleEnabled ? "开启" : "暂停")。",
                userText: includeNames ? ["course_name": String(course.name.prefix(80))] : [:])
            add("\(alias)：有效最小块\(course.minimumBlockMinutes > 0 ? course.minimumBlockMinutes : state.settings.minimumScheduleUnit)分钟；分节\(state.lessonWorkItems(for: course).count)节。当前未来待确认安排\(booked)分钟，其中按开始日在截止日内\(inDeadline)分钟；与剩余量差额\(max(0, remaining - inDeadline))分钟。差额只是已存课表的统计，不证明容量不足。")
            add("\(alias)：从当前/开始日至截止日共有\(days)个自然日；剩余量÷自然日=\(days > 0 ? String(format: "%.1f", Double(remaining) / Double(days)) : "无法计算")分钟/日，仅为算术参考，不是算法的可学习日均摊目标，也不是每日上限。")
            if let demand = result?.demands[course.id] {
                add("\(alias)：当前排程评估的可学习日\(demand.learnableDays)天，评估剩余量\(demand.remainingMinutes)分钟，界面每日均摊\(String(format: "%.1f", demand.averageMinutesPerDay))分钟。偏好可受整节课、休息、截止压力和更高等级偏好影响；这里不能确认当初具体触发了哪条规则。")
            }
        }
        let selectedNames = Set(selected.map(\.name))
        let conflicts = (result?.conflicts ?? []).filter {
            courseID == nil || ($0.courseIDs.map { !ids.isDisjoint(with: $0) }
                ?? !$0.courseNames.allSatisfy { !selectedNames.contains($0) })
        }
        for conflict in conflicts.prefix(8) {
            let related = conflict.courseIDs.map { relatedIDs in courses.filter { relatedIDs.contains($0.id) } }
                ?? courses.filter { conflict.courseNames.contains($0.name) }
            let relatedAliases = related.prefix(24).compactMap { aliases[$0.id] }.joined(separator: "、")
            let relation = "关联课程：\(relatedAliases.isEmpty ? "无法对应编号" : relatedAliases)"
                + (related.count > 24 ? "（另有\(related.count - 24)门未列出）" : "")
                + (conflict.courseIDs == nil ? "（原评估仅记录名称；同名时为候选编号，不能唯一归属）" : "")
            let kind = conflict.restConflict != nil ? "课间休息冲突" : (conflict.minimumContinuousMinutes != nil ? "连续空档冲突" : "容量约束")
            var details = ""
            if let rest = conflict.restConflict {
                details = "学习\(rest.requiredStudyMinutes)分钟＋至少休息\(rest.minimumRestMinutes)分钟＞可用\(rest.availableMinutes)分钟。这是当前空档下的必要休息预算，不是必须删除的学习量；未排入分钟数也不等于缺口。"
            } else if let minimum = conflict.minimumContinuousMinutes {
                details = "至少需要连续\(minimum)分钟，最长连续空档\(conflict.availableMinutes)分钟；不能把分散空档相加当作连续时间。"
            }
            add("当前评估\(kind)；\(relation)：\(stamp(conflict.windowStart))至\(stamp(conflict.deadline))，需要\(conflict.requiredMinutes)分钟、可用\(conflict.availableMinutes)分钟；\(conflict.provenDeficit.map { "已证实容量缺口\($0)分钟" } ?? "不能将两个数字简单相减当作容量缺口")。\(details)")
        }
        if conflicts.count > 8 { add("另有\(conflicts.count - 8)项约束冲突未列出。") }
        let tasks = state.tasks.filter { ids.contains($0.courseID) && calendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
        add("所选课程在此日已存安排合计\(tasks.reduce(0) { $0 + $1.durationMinutes })分钟；含历史安排，不能当作实际学习量。")
        for task in tasks.prefix(24) {
            add("\(aliases[task.courseID] ?? "未知课程")：\(stamp(task.start))–\(stamp(task.end))，安排\(task.durationMinutes)分钟，记录完成\(task.completedMinutes)分钟，状态\(task.status.rawValue)，\(task.isUnconfirmed ? "待确认" : "历史记录")\(task.isFloating ? "；属于浮动窗口，显示时间不代表整个窗口" : "")。")
        }
        if tasks.count > 24 { add("另有\(tasks.count - 24)条当日安排未列出。") }
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        let taskIndex = Dictionary(state.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dated = state.completions.filter { ids.contains($0.courseID) }.map {
            (record: $0, day: analyzer.effectiveDay($0, task: taskIndex[$0.taskID]))
        }
        let completions = dated.filter { $0.day.map { calendar.isDate($0.date, inSameDayAs: day) } == true }
        let uncertain = dated.filter { $0.day == nil }
        func total(_ minutes: [Int]) -> String {
            var result = 0
            for value in minutes {
                let (sum, overflow) = result.addingReportingOverflow(value)
                guard !overflow else { return "无法计算（合计溢出）" }
                result = sum
            }
            return "\(result)分钟"
        }
        add("所选课程按实际学习日统计：\(completions.count)条确认，合计\(total(completions.map { $0.record.minutes }))；其中同日确认的旧记录\(completions.filter { $0.day?.legacy == true }.count)条。旧记录只有关联任务与登记同日才归入该日；补登记采用明确的学习日期，不能直接采用登记日。重复学习不一定增加有效课程进度。")
        add("所选课程日期不明的旧记录：\(uncertain.count)条，合计\(total(uncertain.map { $0.record.minutes }))；覆盖所选课程全部记录，不归入任何具体日期的实际学习量，仍保留课程总进度。")
        add("缺失信息：未提供其他日期的逐条事项、课节名称、历史设置、当时搜索过程或完整历史。无法确认某个时段的唯一成因；需要时应切换日期/课程核对。当前没有提供某门课每日硬上限，不能编造超标阈值。")
        return .init(facts: facts, capturedAt: now,
                     courseAliases: selected.map { "\(aliases[$0.id]!) = \(AssistantFact.escapedJSON($0.name))" })
    }
}
