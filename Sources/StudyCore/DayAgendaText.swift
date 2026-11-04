import Foundation

/// A read-only text snapshot of the same local day shown by the calendar.
/// Notes, source links, and completion-record metadata are intentionally omitted.
public enum DayAgendaText {
    public static func make(day: Date, state: PlannerState, calendar: Calendar = .current) -> String {
        let names = Dictionary(state.courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = calendar.timeZone
        format.dateFormat = "yyyy-MM-dd EEEE"
        var lines = ["学习日程 · \(format.string(from: day))", "时区：\(calendar.timeZone.identifier)"]
        func oneLine(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        func clock(_ value: Date, withOffset: Bool) -> String {
            format.dateFormat = calendar.isDate(value, inSameDayAs: day) ? "HH:mm" : "yyyy-MM-dd HH:mm"
            if withOffset { format.dateFormat += " XXX" }
            return format.string(from: value)
        }
        func range(_ start: Date, _ end: Date) -> String {
            let offsetsDiffer = calendar.timeZone.secondsFromGMT(for: start) != calendar.timeZone.secondsFromGMT(for: end)
            return clock(start, withOffset: offsetsDiffer) + "–" + clock(end, withOffset: offsetsDiffer)
        }
        func minute(_ value: Int) -> String { String(format: "%02d:%02d", value / 60, value % 60) }
        struct Row { var start: Date; var id: String; var text: String }
        var planned: [Row] = [], history: [Row] = [], skipped: [Row] = []
        for task in state.tasks where calendar.isDate(task.start, inSameDayAs: day) {
            let course = names[task.courseID]
            guard course?.isArchived == false || !task.isUnconfirmed else { continue }
            var title = oneLine(course?.name ?? "已删除课程")
            if let lesson = task.lessonName, !oneLine(lesson).isEmpty { title += " / " + oneLine(lesson) }
            var text = (task.isFloating ? "预估 " : "") + range(task.start, task.end) + " · " + title
            text += " · 计划 \(task.durationMinutes) 分钟"
            if task.isFloating { text += " · 完成窗口：" + range(task.planningStart, task.planningEnd) }
            if task.isUnconfirmed { text += " · 未确认" }
            else { text += task.completedMinutes == 0 ? " · 未完成" : " · 已确认 \(task.completedMinutes) 分钟" }
            let row = Row(start: task.start, id: "task-" + task.id.uuidString, text: text)
            if task.isUnconfirmed { planned.append(row) } else { history.append(row) }
        }
        let engine = ScheduleEngine(calendar: calendar)
        for event in state.fixedEvents where event.occurs(on: day, calendar: calendar, includingExcluded: true) {
            let excluded = !event.occurs(on: day, calendar: calendar)
            var text = minute(event.startMinute) + "–" + minute(event.endMinute) + " · " + oneLine(event.title)
            text += event.isFloating ? " · 浮动窗口，需 \(event.occupiedMinutes) 分钟" : " · 固定事项"
            if excluded { text += " · 本日不占用时间" }
            let row = Row(start: engine.instant(day: day, minute: event.startMinute), id: "event-" + event.id.uuidString, text: text)
            if excluded { skipped.append(row) } else { planned.append(row) }
        }
        func append(_ title: String, _ rows: [Row]) {
            guard !rows.isEmpty else { return }
            lines += ["", title]
            lines += rows.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.map { "• " + $0.text }
        }
        if planned.isEmpty { lines += ["", "这一天没有待进行的安排"] }
        else { append("待进行的安排", planned) }
        append("原计划对应的完成记录", history)
        if !history.isEmpty { lines.append("完成记录按原计划日期列出，不代表当天实际学习总量。") }
        append("本日已临时移除", skipped)
        return lines.joined(separator: "\n")
    }
}
