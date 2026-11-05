import Foundation

/// A transient explanation of a failed event reservation; never changes saved rules.
public struct FloatingScheduleIssue: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        case continuousGap(required: Int, longest: Int)
        case totalCapacity(required: Int, available: Int)
        case unresolved
    }

    public var date: Date
    public var events: [FixedEvent]
    public var reason: Reason
    public var id: Date { date }
    public var isProvenConflict: Bool { reason != .unresolved }
    public var explanation: String {
        switch reason {
        case let .continuousGap(required, longest):
            return "浮动事项需要连续 \(required) 分钟，扣除固定事项后，窗口内最长连续空档只有 \(longest) 分钟。即使不安排学习也无法容纳。"
        case let .totalCapacity(required, available):
            return "这些浮动事项共需 \(required) 分钟，窗口合并并扣除固定事项后最多只有 \(available) 分钟，至少缺少 \(required - available) 分钟。增加时间后仍需满足各事项的连续时长。"
        case .unresolved:
            return "本次未找到这些浮动事项的完整排法，尚不能据此断定时间不足。它们的窗口暂不安排学习，避免重复占用。"
        }
    }
    public var recovery: String {
        "请核对当天事项，可扩大浮动窗口、缩短占用时长或移动固定事项。只处理这一天时，可在日程中跳过当次安排；已开始的重复事项，修改规则从后续日期生效。"
    }

    /// Called only after reservation fails. Bounds ignore other floating events
    /// when checking continuity and use union capacity, never a heuristic deficit.
    static func diagnose(events: [FixedEvent], on date: Date, calendar: Calendar) -> Self {
        let day = calendar.startOfDay(for: date), engine = ScheduleEngine(calendar: calendar)
        let end = engine.instant(day: day, minute: 1440)
        let count = max(0, Int(end.timeIntervalSince(day) / 60))
        let valid = events.filter(\.hasValidTimeWindow)
        let floating = valid.filter(\.isFloating).sorted {
            $0.startMinute != $1.startMinute ? $0.startMinute < $1.startMinute : $0.id.uuidString < $1.id.uuidString
        }
        func range(_ event: FixedEvent) -> Range<Int> {
            let start = engine.instant(day: day, minute: event.startMinute)
            let end = engine.instant(day: day, minute: event.endMinute)
            let lower = min(count, max(0, Int(ceil(start.timeIntervalSince(day) / 60))))
            let upper = min(count, max(lower, Int(floor(end.timeIntervalSince(day) / 60))))
            return lower..<upper
        }
        let exact = valid.filter { !$0.isFloating }
        var busy = [Bool](repeating: false, count: count)
        for event in exact { for minute in range(event) { busy[minute] = true } }
        var coverage = [Bool](repeating: false, count: count)
        for event in floating {
            let window = range(event)
            var longest = 0, current = 0
            for minute in window {
                if busy[minute] { current = 0 }
                else { current += 1; longest = max(longest, current); coverage[minute] = true }
            }
            if longest < event.occupiedMinutes {
                let blockers = exact.filter { range($0).overlaps(window) }
                return .init(date: day, events: [event] + blockers,
                             reason: .continuousGap(required: event.occupiedMinutes, longest: longest))
            }
        }
        let required = floating.reduce(0) { $0 + $1.occupiedMinutes }
        let available = coverage.filter { $0 }.count
        let blockers = exact.filter { event in floating.contains { range($0).overlaps(range(event)) } }
        return .init(date: day, events: floating + blockers,
                     reason: required > available ? .totalCapacity(required: required, available: available) : .unresolved)
    }
}
