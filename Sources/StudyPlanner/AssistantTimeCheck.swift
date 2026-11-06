import Foundation
import StudyCore

/// Read-only interval facts. A floating window is never treated as an occupied interval.
enum AssistantTimeCheck {
    private struct Span {
        let start: Date
        let end: Date
    }
    private struct Item {
        let kind: String
        let id: String
        let span: Span
        let minutes: Int
    }
    private static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.filter({ $0.start < $0.end }).sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1] = Span(start: last.start, end: max(last.end, span.end))
            } else { result.append(span) }
        }
        return result
    }
    private static func free(_ windows: [Span], excluding blocks: [Span]) -> [Span] {
        var result = merged(windows)
        for block in merged(blocks) {
            result = result.flatMap { span -> [Span] in
                guard block.start < span.end, block.end > span.start else { return [span] }
                var parts: [Span] = []
                if span.start < block.start { parts.append(Span(start: span.start, end: block.start)) }
                if block.end < span.end { parts.append(Span(start: block.end, end: span.end)) }
                return parts
            }
        }
        return result
    }
    static func inspect(snapshot: AssistantSnapshot, day: Date, offset: Int) throws -> [String: Any] {
        let end = snapshot.calendar.date(byAdding: .day, value: 1, to: day)!
        let engine = ScheduleEngine(calendar: snapshot.calendar)
        let tasks = snapshot.state.tasks.filter { $0.planningStart < end && $0.planningEnd > day }
        let events = snapshot.state.fixedEvents.filter { $0.occurs(on: day, calendar: snapshot.calendar) }
        guard tasks.count + events.count <= 500 else { throw AssistantError.limit }
        guard offset >= 0 else { throw AssistantError.protocolError }
        var fixed: [Item] = [], floating: [Item] = [], invalid = 0, historical = 0
        for task in tasks {
            guard task.isUnconfirmed else { historical += 1; continue }
            guard task.durationMinutes > 0, task.planningStart.timeIntervalSince1970.isFinite,
                  task.planningEnd.timeIntervalSince1970.isFinite, task.planningStart < task.planningEnd else { invalid += 1; continue }
            let item = Item(kind: "study", id: task.id.uuidString,
                            span: Span(start: task.planningStart, end: task.planningEnd), minutes: task.durationMinutes)
            if task.isFloating { floating.append(item) } else { fixed.append(item) }
        }
        for event in events {
            guard event.startMinute >= 0, event.endMinute <= 1440, event.startMinute < event.endMinute,
                  event.validDuration else { invalid += 1; continue }
            let item = Item(kind: "event", id: event.id.uuidString,
                            span: Span(start: engine.instant(day: day, minute: event.startMinute),
                                       end: engine.instant(day: day, minute: event.endMinute)), minutes: event.occupiedMinutes)
            if event.isFloating { floating.append(item) } else { fixed.append(item) }
        }
        fixed.sort { $0.span.start != $1.span.start ? $0.span.start < $1.span.start : $0.id < $1.id }
        floating.sort { $0.span.start != $1.span.start ? $0.span.start < $1.span.start : $0.id < $1.id }
        func reference(_ item: Item) -> [String: Any] {
            ["kind": item.kind, "id": item.id, "start": snapshot.stamp(item.span.start, time: true), "end": snapshot.stamp(item.span.end, time: true)]
        }
        var rows: [[String: Any]] = [], rowCount = 0, overlaps = 0, deficits = 0, jointDeficits = 0
        func record(_ value: @autoclosure () -> [String: Any]) {
            if rowCount >= offset, rowCount - offset < 20 { rows.append(value()) }
            rowCount += 1
        }
        // Compare every intersecting pair, including nested intervals, not just neighbours.
        for i in fixed.indices {
            for j in fixed.indices where j > i {
                if fixed[j].span.start >= fixed[i].span.end { break }
                let lower = max(day, max(fixed[i].span.start, fixed[j].span.start))
                let upper = min(end, min(fixed[i].span.end, fixed[j].span.end))
                guard lower < upper else { continue }
                overlaps += 1
                record(["kind": "fixed_overlap", "first": reference(fixed[i]), "second": reference(fixed[j]),
                             "overlap_start": snapshot.stamp(lower, time: true), "overlap_end": snapshot.stamp(upper, time: true),
                             "overlap_minutes": upper.timeIntervalSince(lower) / 60])
            }
        }
        let blocks = fixed.map(\.span)
        var checkedFloating: [Item] = []
        for item in floating {
            // One day's evidence cannot prove feasibility for a multi-day window.
            guard item.span.start >= day, item.span.end <= end else {
                record(["kind": "floating_window", "item": reference(item), "required_minutes": item.minutes,
                             "result": "outside_day_not_checked"])
                continue
            }
            checkedFloating.append(item)
            let gaps = free([item.span], excluding: blocks)
            let longest = gaps.map { $0.end.timeIntervalSince($0.start) / 60 }.max() ?? 0
            let available = gaps.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
            let deficit = longest < Double(item.minutes)
            if deficit { deficits += 1 }
            record(["kind": "floating_window", "item": reference(item), "required_minutes": item.minutes,
                         "available_minutes": available, "longest_free_minutes": longest,
                         "result": deficit ? "proven_continuous_deficit" : "individually_fits",
                         "note": "仅扣除固定时段核对单项连续空档；不代表实际安排，也不证明多项浮动任务能同时排入。"])
        }
        // A union-capacity bound can prove a joint deficit; passing it is not a feasibility proof.
        var components: [[Item]] = []
        for item in checkedFloating {
            if let last = components.last, let upper = last.map(\.span.end).max(), item.span.start < upper {
                components[components.count - 1].append(item)
            } else { components.append([item]) }
        }
        for group in components where group.count > 1 {
            let required = group.reduce(0.0) { $0 + Double($1.minutes) }
            let available = free(group.map(\.span), excluding: blocks).reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
            if required > available {
                deficits += 1
                jointDeficits += 1
                record(["kind": "floating_total_deficit", "items": group.map(reference),
                             "required_minutes": required, "available_minutes": available, "deficit_minutes": required - available])
            }
        }
        guard offset <= rowCount else { throw AssistantError.protocolError }
        let upper = offset + rows.count
        return ["date": snapshot.stamp(day), "fixed_interval_count": fixed.count, "fixed_overlap_count": overlaps,
                "floating_window_count": floating.count, "proven_floating_deficit_count": deficits,
                "excluded_confirmed_task_count": historical, "invalid_entry_count": invalid,
                "fixed_check_complete": invalid == 0, "joint_floating_status": jointDeficits > 0 ? "proven_deficit" : (floating.count > 1 ? "not_verified" : "not_applicable"),
                "rows": rows, "total": rowCount,
                "next_offset": upper < rowCount ? String(upper) as Any : NSNull(),
                "source": "AssistantTimeCheck", "note": "只核对指定日期的已存计划。固定时段逐对取区间交集，首尾相接不算重叠；休息不足另查排程规则。已确认、完成、部分完成、错过和重排的旧任务不作为待执行占用，其原计划不等于实际学习时间。浮动窗口不是实际占用，单项可容纳不等于联合可行；未核实或无效数据不得说成没有冲突。容量缺口与固定时间重叠是两类结论。"]
    }
}
