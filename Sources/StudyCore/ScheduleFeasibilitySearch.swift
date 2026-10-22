import Foundation

/// Bounded rescue search. Failure means unknown, never a proof of infeasibility.
/// Each state interleaves ordered lesson queues and the dated floating events.
enum ScheduleFeasibilitySearch {
    struct Window { var start: Int; var end: Int }
    struct Work { var minutes: Int; var lessonID: String?; var lessonName: String? }
    struct Queue { var courseID: UUID; var start: Int; var end: Int; var work: [Work] }
    struct Floating { var key: Date; var start: Int; var end: Int; var minutes: Int }
    struct Solution { var tasks: [ScheduledTask]; var floatingStarts: [Date: Int] }
    private struct Key: Hashable { var positions: [Int]; var floating: Int; var lastStudy: Bool }
    private struct Node { var key: Key; var end: Int; var parent: Int; var choice: Int; var start: Int; var score: Double }

    static func find(queues: [Queue], study: [Window], eventWindows: [Window], floating: [Floating],
                     floor: Int, initial: Int, beamWidth: Int = 128, expansionLimit: Int = 250_000) -> Solution? {
        guard !queues.isEmpty, queues.count <= 6, queues.reduce(0, { $0 + $1.work.count }) <= 600,
              floating.allSatisfy({ $0.minutes >= ScheduleEngine.breakMinutes }),
              study.count <= 1500, floating.count <= 366 else { return nil }
        let infinity = Int.max / 4
        func place(_ windows: [Window], after: Int, minutes: Int, deadline: Int) -> Int? {
            var lo = 0, hi = windows.count
            while lo < hi { let m = (lo + hi) / 2; if windows[m].end < after + minutes { lo = m + 1 } else { hi = m } }
            for index in lo..<windows.count {
                let start = max(after, windows[index].start), end = start + minutes
                if end > deadline { return nil }
                if end <= windows[index].end { return start }
            }
            return nil
        }
        var suffix: [[Int]] = [], latest: [[Int]] = []
        for queue in queues {
            var sums = [Int](repeating: 0, count: queue.work.count + 1)
            var starts = [Int](repeating: infinity, count: queue.work.count + 1)
            var end = queue.end
            for index in queue.work.indices.reversed() {
                sums[index] = sums[index + 1] + queue.work[index].minutes
                guard let window = study.last(where: { min(end, $0.end) - queue.work[index].minutes >= max($0.start, queue.start, floor) }) else { return nil }
                starts[index] = min(end, window.end) - queue.work[index].minutes
                end = starts[index] - ScheduleEngine.breakMinutes
            }
            suffix.append(sums); latest.append(starts)
        }
        let deadlines = Set(queues.map(\.end)).sorted()
        var floatingCostPrefix = [0]
        for event in floating {
            var least = infinity
            for window in eventWindows {
                let first = max(window.start, event.start), last = min(window.end, event.end) - event.minutes
                if first > last { continue }
                for start in first...last {
                    let end = start + event.minutes
                    let overlap = study.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
                    least = min(least, overlap)
                }
            }
            if least == infinity { return nil }
            floatingCostPrefix.append(floatingCostPrefix.last! + least)
        }
        let floatingCutoffs = deadlines.map { cutoff in floating.prefix { $0.end <= cutoff }.count }
        func rank(_ key: Key, end: Int) -> Double? {
            let ready = max(floor, end + (key.lastStudy ? ScheduleEngine.breakMinutes : 0))
            for c in queues.indices where key.positions[c] < queues[c].work.count {
                if max(ready, queues[c].start) > latest[c][key.positions[c]] { return nil }
            }
            var stress = 0.0
            for (d, cutoff) in deadlines.enumerated() {
                var required = 0, blocks = 0
                for c in queues.indices where queues[c].end <= cutoff {
                    required += suffix[c][key.positions[c]]; blocks += queues[c].work.count - key.positions[c]
                }
                if required == 0 { continue }
                var capacity = 0, regions = 0
                for window in study where window.end > max(floor, end) && window.start < cutoff {
                    capacity += max(0, min(cutoff, window.end) - max(floor, end, window.start)); regions += 1
                }
                let events = max(0, floatingCutoffs[d] - key.floating)
                if events > 0 { capacity -= floatingCostPrefix[floatingCutoffs[d]] - floatingCostPrefix[key.floating] }
                required += ScheduleEngine.breakMinutes * max(0, blocks - regions - events)
                if required > capacity { return nil }
                stress = max(stress, Double(required) / Double(max(1, capacity)))
            }
            return stress
        }
        let first = Key(positions: queues.map { _ in 0 }, floating: 0, lastStudy: false)
        var nodes = [Node(key: first, end: initial, parent: -1, choice: -2, start: initial, score: 0)]
        var beam = [0], expansions = 0
        let steps = queues.reduce(floating.count) { $0 + $1.work.count }
        for _ in 0..<steps {
            var candidates: [Key: Node] = [:]
            for index in beam {
                let previous = nodes[index]
                for choice in -1..<queues.count {
                    expansions += 1
                    if expansions > expansionLimit { return nil }
                    var key = previous.key
                    let start: Int, minutes: Int
                    if choice == -1 {
                        guard key.floating < floating.count else { continue }
                        let event = floating[key.floating]
                        guard let at = place(eventWindows, after: max(previous.end, event.start), minutes: event.minutes, deadline: event.end) else { continue }
                        start = at; minutes = event.minutes; key.floating += 1; key.lastStudy = false
                    } else {
                        let queue = queues[choice], position = key.positions[choice]
                        guard position < queue.work.count else { continue }
                        minutes = queue.work[position].minutes
                        let after = max(floor, queue.start, previous.end + (key.lastStudy ? ScheduleEngine.breakMinutes : 0))
                        // An outstanding floating event must still fit after this lesson.
                        let eventDeadline = key.floating < floating.count ? floating[key.floating].end - floating[key.floating].minutes : infinity
                        guard let at = place(study, after: after, minutes: minutes, deadline: min(queue.end, eventDeadline)) else { continue }
                        start = at; key.positions[choice] += 1; key.lastStudy = true
                    }
                    let end = start + minutes
                    if let old = candidates[key], old.end <= end { continue }
                    guard let score = rank(key, end: end) else { continue }
                    candidates[key] = Node(key: key, end: end, parent: index, choice: choice, start: start, score: score)
                }
            }
            if candidates.isEmpty { return nil }
            let selected = candidates.values.sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                if $0.end != $1.end { return $0.end < $1.end }
                if $0.key.positions != $1.key.positions { return $0.key.positions.lexicographicallyPrecedes($1.key.positions) }
                if $0.key.floating != $1.key.floating { return $0.key.floating < $1.key.floating }
                return !$0.key.lastStudy && $1.key.lastStudy
            }.prefix(beamWidth)
            beam = []
            for node in selected { beam.append(nodes.count); nodes.append(node) }
        }
        guard let final = beam.min(by: { nodes[$0].end < nodes[$1].end }) else { return nil }
        var path: [Node] = [], index = final
        while nodes[index].parent >= 0 { path.append(nodes[index]); index = nodes[index].parent }
        var solution = Solution(tasks: [], floatingStarts: [:])
        for node in path.reversed() {
            if node.choice == -1 { solution.floatingStarts[floating[node.key.floating - 1].key] = node.start }
            else {
                let queue = queues[node.choice], work = queue.work[node.key.positions[node.choice] - 1]
                solution.tasks.append(.init(courseID: queue.courseID, start: Date(timeIntervalSinceReferenceDate: Double(node.start) * 60),
                                            durationMinutes: work.minutes, lessonID: work.lessonID, lessonName: work.lessonName))
            }
        }
        return solution
    }
}
