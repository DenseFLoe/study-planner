import Foundation

/// Bounded rescue search. Failure means unknown, never a proof of infeasibility.
/// Each state interleaves ordered lessons and any remaining event on the earliest
/// unfinished event day. Short events consume elapsed rest, never reset it.
enum ScheduleFeasibilitySearch {
    struct Window { var start: Int; var end: Int }
    struct Work { var minutes: Int; var lessonID: String?; var lessonName: String? }
    struct Queue { var courseID: UUID; var start: Int; var end: Int; var work: [Work] }
    struct Floating { var key: Date; var start: Int; var end: Int; var minutes: Int }
    // Original occurrence indices distinguish multiple events on the same day.
    struct Solution { var tasks: [ScheduledTask]; var floatingStarts: [Int: Int] }
    private struct Key: Hashable { var positions: [Int]; var group: Int; var mask: Int; var rest: Int }
    private struct Node { var key: Key; var end: Int; var parent: Int; var choice: Int; var start: Int; var score: Double }

    static func find(queues: [Queue], study: [Window], eventWindows: [Window], floating: [Floating],
                     floor: Int, initial: Int, beamWidth: Int = 128, expansionLimit: Int = 250_000) -> Solution? {
        guard !Task.isCancelled, beamWidth > 0, expansionLimit > 0,
              !queues.isEmpty, queues.count <= 6, queues.reduce(0, { $0 + $1.work.count }) <= 600,
              floating.allSatisfy({ $0.minutes > 0 && $0.minutes <= $0.end - $0.start }),
              study.count <= 1500, floating.count <= 366 else { return nil }
        let infinity = Int.max / 4
        let eventOrder = floating.indices.sorted {
            let a = floating[$0], b = floating[$1]
            if a.key != b.key { return a.key < b.key }
            if a.end != b.end { return a.end < b.end }
            if a.start != b.start { return a.start < b.start }
            if a.minutes != b.minutes { return a.minutes < b.minutes }
            return $0 < $1
        }
        var groups: [[Int]] = []
        for index in eventOrder {
            if let last = groups.last, floating[last[0]].key == floating[index].key {
                groups[groups.count - 1].append(index)
            } else { groups.append([index]) }
        }
        // A bit mask explores event order within a day without a horizon-wide
        // subset state. Larger combinations remain unknown, not infeasible.
        guard groups.allSatisfy({ $0.count <= 8 }) else { return nil }
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
        var eventCosts = [Int](repeating: 0, count: floating.count)
        var eventLatest = [Int](repeating: -infinity, count: floating.count)
        for (index, event) in floating.enumerated() {
            if Task.isCancelled { return nil }
            var least = infinity
            let localStudy = study.filter { $0.end > event.start && $0.start < event.end }
            for window in eventWindows {
                let first = max(window.start, event.start), last = min(window.end, event.end) - event.minutes
                if first > last { continue }
                for start in first...last {
                    let end = start + event.minutes
                    let overlap = localStudy.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
                    least = min(least, overlap)
                }
                eventLatest[index] = max(eventLatest[index], last)
            }
            if least == infinity { return nil }
            eventCosts[index] = least
        }
        var futureCosts = [[Int]](repeating: [Int](repeating: 0, count: deadlines.count), count: groups.count + 1)
        var futureLatest = [Int](repeating: infinity, count: groups.count + 1)
        for g in groups.indices.reversed() {
            futureCosts[g] = futureCosts[g + 1]
            futureLatest[g] = futureLatest[g + 1]
            for f in groups[g] {
                futureLatest[g] = min(futureLatest[g], eventLatest[f])
                for d in deadlines.indices where floating[f].end <= deadlines[d] { futureCosts[g][d] += eventCosts[f] }
            }
        }
        func pendingEvents(_ key: Key) -> [Int] {
            guard key.group < groups.count else { return [] }
            return groups[key.group].enumerated().filter { key.mask & (1 << $0.offset) == 0 }.map(\.element)
        }
        func rank(_ key: Key, end: Int) -> Double? {
            let ready = max(floor, end + key.rest)
            for c in queues.indices where key.positions[c] < queues[c].work.count {
                if max(ready, queues[c].start) > latest[c][key.positions[c]] { return nil }
            }
            let pending = pendingEvents(key)
            if pending.contains(where: { end > eventLatest[$0] }) { return nil }
            if key.group < groups.count && end > futureLatest[key.group + 1] { return nil }
            var stress = 0.0
            for (d, cutoff) in deadlines.enumerated() {
                var required = 0
                for c in queues.indices where queues[c].end <= cutoff {
                    required += suffix[c][key.positions[c]]
                }
                if required == 0 { continue }
                var capacity = 0
                for window in study where window.end > max(floor, end) && window.start < cutoff {
                    capacity += max(0, min(cutoff, window.end) - max(floor, end, window.start))
                }
                if key.group < groups.count {
                    capacity -= futureCosts[key.group + 1][d]
                    for f in pending where floating[f].end <= cutoff { capacity -= eventCosts[f] }
                }
                // Optimistically ignore remaining breaks here: events may occupy
                // those gaps, including events whose windows end after cutoff.
                if required > capacity { return nil }
                stress = max(stress, Double(required) / Double(max(1, capacity)))
            }
            return stress
        }
        let first = Key(positions: queues.map { _ in 0 }, group: 0, mask: 0, rest: 0)
        var nodes = [Node(key: first, end: initial, parent: -1, choice: -2, start: initial, score: 0)]
        var beam = [0], expansions = 0
        let steps = queues.reduce(floating.count) { $0 + $1.work.count }
        for _ in 0..<steps {
            if Task.isCancelled { return nil }
            var candidates: [Key: Node] = [:]
            for index in beam {
                let previous = nodes[index]
                let pending = pendingEvents(previous.key)
                let choices = pending.map { -1 - $0 } + Array(queues.indices)
                for choice in choices {
                    expansions += 1
                    if expansions > expansionLimit { return nil }
                    var key = previous.key
                    let start: Int, minutes: Int
                    if choice < 0 {
                        let f = -1 - choice, event = floating[f]
                        guard let at = place(eventWindows, after: max(previous.end, event.start), minutes: event.minutes, deadline: event.end) else { continue }
                        start = at; minutes = event.minutes
                        let bit = groups[key.group].firstIndex(of: f)!
                        key.mask |= 1 << bit
                        if key.mask == (1 << groups[key.group].count) - 1 { key.group += 1; key.mask = 0 }
                        key.rest = max(0, previous.end + previous.key.rest - (start + minutes))
                    } else {
                        let queue = queues[choice], position = key.positions[choice]
                        guard position < queue.work.count else { continue }
                        minutes = queue.work[position].minutes
                        let after = max(floor, queue.start, previous.end + key.rest)
                        // An outstanding floating event must still fit after this lesson.
                        let eventDeadline = min(pending.map { eventLatest[$0] }.min() ?? infinity,
                                                key.group < groups.count ? futureLatest[key.group + 1] : infinity)
                        guard let at = place(study, after: after, minutes: minutes, deadline: min(queue.end, eventDeadline)) else { continue }
                        start = at; key.positions[choice] += 1; key.rest = ScheduleEngine.breakMinutes
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
                if $0.key.group != $1.key.group { return $0.key.group < $1.key.group }
                if $0.key.mask != $1.key.mask { return $0.key.mask < $1.key.mask }
                return $0.key.rest < $1.key.rest
            }.prefix(beamWidth)
            beam = []
            for node in selected { beam.append(nodes.count); nodes.append(node) }
        }
        guard let final = beam.min(by: { nodes[$0].end < nodes[$1].end }) else { return nil }
        var path: [Node] = [], index = final
        while nodes[index].parent >= 0 { path.append(nodes[index]); index = nodes[index].parent }
        var solution = Solution(tasks: [], floatingStarts: [:])
        for node in path.reversed() {
            if node.choice < 0 { solution.floatingStarts[-1 - node.choice] = node.start }
            else {
                let queue = queues[node.choice], work = queue.work[node.key.positions[node.choice] - 1]
                solution.tasks.append(.init(courseID: queue.courseID, start: Date(timeIntervalSinceReferenceDate: Double(node.start) * 60),
                                            durationMinutes: work.minutes, lessonID: work.lessonID, lessonName: work.lessonName))
            }
        }
        return solution
    }
}
