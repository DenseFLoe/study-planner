import Foundation

public enum WeeklyStudyReportError: LocalizedError, Sendable {
    case unavailable
    public var errorDescription: String? { "周统计无法合计，请核对任务与学习时长；原记录已保留。" }
}

/// A detached, read-only report of planned time and actual study dates.
public struct WeeklyStudyReport: Sendable {
    public let rangeLabel: String
    public let text: String

    private struct Row {
        let id: UUID
        let name: String
        var planned = Array(repeating: 0, count: 7)
        var studied = Array(repeating: 0, count: 7)
    }
    private static func add(_ left: Int, _ right: Int) throws -> Int {
        let sum = left.addingReportingOverflow(right)
        guard left >= 0, right >= 0, !sum.overflow else { throw WeeklyStudyReportError.unavailable }
        return sum.partialValue
    }
    private static func sum(_ values: [Int]) throws -> Int { try values.reduce(0, add) }

    public static func make(day: Date, state: PlannerState, calendar: Calendar = .current) throws -> WeeklyStudyReport {
        let selected = calendar.startOfDay(for: day)
        let offset = (calendar.component(.weekday, from: selected) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset, to: selected),
              let end = calendar.date(byAdding: .day, value: 7, to: monday) else { throw WeeklyStudyReportError.unavailable }
        let days = try (0..<7).map { index -> Date in
            guard let value = calendar.date(byAdding: .day, value: index, to: monday) else { throw WeeklyStudyReportError.unavailable }
            return value
        }
        func index(_ date: Date) -> Int? {
            guard date >= monday, date < end,
                  let day = calendar.dateComponents([.day], from: monday, to: calendar.startOfDay(for: date)).day,
                  (0..<7).contains(day) else { return nil }
            return day
        }
        let courses = Dictionary(state.courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func row(_ id: UUID) -> Row {
            let name = (courses[id]?.name ?? "已删除课程").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return Row(id: id, name: name.isEmpty ? "未命名课程" : name)
        }
        var rows: [UUID: Row] = [:], tasks: [UUID: ScheduledTask] = [:]
        var planned = Array(repeating: 0, count: 7), studied = Array(repeating: 0, count: 7), undated = 0
        for task in state.tasks {
            if tasks[task.id] == nil { tasks[task.id] = task }
            guard let day = index(task.start) else { continue }
            var value = rows[task.courseID] ?? row(task.courseID)
            value.planned[day] = try add(value.planned[day], task.durationMinutes)
            planned[day] = try add(planned[day], task.durationMinutes); rows[task.courseID] = value
        }
        let analyzer = DailyConsequenceAnalyzer(calendar: calendar)
        for record in state.completions {
            guard let date = analyzer.effectiveDay(record, task: tasks[record.taskID])?.date else {
                undated = try add(undated, record.minutes); continue
            }
            guard let day = index(date) else { continue }
            var value = rows[record.courseID] ?? row(record.courseID)
            value.studied[day] = try add(value.studied[day], record.minutes)
            studied[day] = try add(studied[day], record.minutes); rows[record.courseID] = value
        }
        let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = calendar.timeZone; format.dateFormat = "yyyy-MM-dd"
        let range = format.string(from: monday) + " 至 " + format.string(from: days[6])
        var lines = ["周学习统计 · \(range)", "时区：\(calendar.timeZone.identifier)",
                     "实际已学：\(try sum(studied)) 分钟", "课表计划：\(try sum(planned)) 分钟",
                     "实际已学按实际学习日期归属；课表计划含已确认任务的原计划，随重排变化。", "", "每日明细"]
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        for day in 0..<7 { lines.append("\(format.string(from: days[day])) \(names[day]) · 已学 \(studied[day]) 分钟 / 计划 \(planned[day]) 分钟") }
        let visible = rows.values.filter { $0.planned.contains(where: { $0 > 0 }) || $0.studied.contains(where: { $0 > 0 }) }.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        var counts: [String: Int] = [:], ordinal: [String: Int] = [:]
        for row in visible { counts[row.name, default: 0] += 1 }
        if visible.isEmpty { lines += ["", "本周暂无计划或已学记录。"] }
        else {
            lines += ["", "课程汇总"]
            for row in visible {
                var title = row.name
                if let count = counts[title], count > 1 {
                    ordinal[title, default: 0] += 1; title += "（同名 \(ordinal[title]!)/\(count)）"
                }
                lines.append("• \(title) · 已学 \(try sum(row.studied)) 分钟 / 计划 \(try sum(row.planned)) 分钟")
            }
        }
        if undated > 0 { lines += ["", "全部历史中另有 \(undated) 分钟无法确定学习日期，未计入本周实际已学；原进度与记录均保留。"] }
        return WeeklyStudyReport(rangeLabel: range, text: lines.joined(separator: "\n"))
    }
}
