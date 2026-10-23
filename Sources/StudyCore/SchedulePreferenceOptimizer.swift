import Foundation

/// Improves a feasible timetable without removing, splitting or inventing work.
/// Rules compare the entire plan lexicographically, in the user's saved order.
/// A deterministic operation budget bounds the search; this is not an optimality proof.
enum SchedulePreferenceOptimizer {
    struct Window {
        var start: Date
        var end: Date
    }
    struct Day {
        var date: Date
        var windows: [Window]
    }
    struct Outcome {
        var tasks: [ScheduledTask]
        var improved: Bool
    }

    static func optimize(tasks: [ScheduledTask], courses: [Course], days: [Day],
                         priorities: SchedulePriorities, calendar: Calendar) -> Outcome {
        guard !tasks.isEmpty, !days.isEmpty else { return .init(tasks: tasks, improved: false) }
        return Search(tasks: tasks, courses: courses, days: days,
                      priorities: priorities, calendar: calendar).run()
    }

    private final class Search {
        struct Plan {
            var rows: [[Int]]
            var starts: [Date]
            var score: [Double]
        }
        let tasks: [ScheduledTask]
        let courses: [Course]
        let days: [Day]
        let priorities: SchedulePriorities
        let owners: [Int]
        let allowed: [[Bool]]
        let targets: [[Double]]
        let initialRows: [[Int]]
        var budget: Int
        let rest: TimeInterval = Double(ScheduleEngine.breakMinutes * 60)

        init(tasks: [ScheduledTask], courses: [Course], days: [Day],
             priorities: SchedulePriorities, calendar: Calendar) {
            // Do not depend on array insertion order or dictionary iteration order.
            self.tasks = tasks.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.courseID.uuidString < $1.courseID.uuidString
            }
            self.courses = courses.sorted { $0.id.uuidString < $1.id.uuidString }
            self.days = days; self.priorities = priorities
            let courseIndices = Dictionary(uniqueKeysWithValues: self.courses.enumerated().map { ($0.element.id, $0.offset) })
            owners = self.tasks.map { courseIndices[$0.courseID]! }
            allowed = self.courses.map { course in
                days.map { $0.date >= calendar.startOfDay(for: course.startDate)
                    && $0.date <= calendar.startOfDay(for: course.deadline) }
            }
            let dayIndices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.date, $0.offset) })
            var rows = [[Int]](repeating: [], count: days.count)
            for i in self.tasks.indices { rows[dayIndices[calendar.startOfDay(for: self.tasks[i].start)]!].append(i) }
            initialRows = rows
            var desired = [[Double]](repeating: [Double](repeating: 0, count: days.count), count: courses.count)
            let sortedTasks = self.tasks, ownerIndices = owners, eligibility = allowed
            for c in self.courses.indices {
                let work = sortedTasks.indices.filter { ownerIndices[$0] == c }
                guard let shortest = work.map({ sortedTasks[$0].durationMinutes }).min() else { continue }
                let learnable = days.indices.filter { eligibility[c][$0] && days[$0].windows.contains {
                    $0.end.timeIntervalSince($0.start) >= Double(shortest * 60)
                } }
                let amount = Double(work.reduce(0) { $0 + sortedTasks[$1].durationMinutes })
                let target = amount * self.courses[c].dailyWeight / Double(max(1, learnable.count))
                var remaining = amount
                for d in learnable { desired[c][d] = min(remaining, target); remaining -= desired[c][d] }
            }
            targets = desired
            // Score and packing cost grow with both the number of lessons and the horizon.
            budget = max(32, min(12_000, 6_000_000 / max(1, tasks.count + days.count * courses.count)))
        }

        func better(_ a: [Double], than b: [Double]) -> Bool {
            for (x, y) in zip(a, b) where abs(x - y) > 0.000001 { return x < y }
            return false
        }

        func score(rows: [[Int]], starts: [Date]) -> [Double] {
            var loads = [[Double]](repeating: [Double](repeating: 0, count: days.count), count: courses.count)
            var totals = [Double](repeating: 0, count: days.count)
            var coverage = 0.0, earlyCoverage = 0.0, repetition = 0.0
            var inversion = 0.0, early = 0.0
            var seen = [Double](repeating: 0, count: courses.count)
            for d in days.indices {
                var present = Set<Int>(), previous: Int?
                var repeats = 0.0
                for t in rows[d] {
                    let c = owners[t], size = Double(tasks[t].durationMinutes)
                    loads[c][d] += size; totals[d] += size; present.insert(c)
                    if previous == c { repeats += 1 }
                    previous = c
                    for other in courses.indices where courses[c].priority > courses[other].priority {
                        inversion += seen[other] * size * Double(courses[c].priority - courses[other].priority)
                    }
                    seen[c] += size
                    early += starts[t].timeIntervalSince(days[0].date) / 60 * size
                }
                // Reward co-presence, capped at three subjects. A fourth subject must
                // not be worth more than preserving three subjects on a later day.
                let count = Double(min(3, present.count)), value = count * (count - 1) / 2
                coverage += value; earlyCoverage += value * Double(days.count - d)
                // A day with just one subject cannot alternate. Do not let this
                // preference silently cancel a lone course's daily boost.
                if present.count >= 2 { repetition += repeats }
            }
            var boost = 0.0, tripleBoost = 0.0, balanced = 0.0, courseBalance = 0.0
            for d in days.indices {
                balanced += totals[d] * totals[d]
                for c in courses.indices {
                    courseBalance += loads[c][d] * loads[c][d]
                    if courses[c].dailyWeight > 1 {
                        let difference = loads[c][d] - targets[c][d]
                        boost += difference * difference
                        if courses[c].dailyWeight == 3 { tripleBoost += difference * difference }
                    }
                }
            }
            // Preserve the documented 3x concentration exception only in default order.
            var values = priorities.usesDefaultOrder ? [tripleBoost] : []
            for rule in priorities.orderedRules {
                switch rule {
                case .diversity: values += [-coverage, -earlyCoverage, repetition]
                case .dailyWeight: values.append(boost)
                case .coursePriority: values.append(inversion)
                case .balancedLoad: values += [balanced, courseBalance]
                }
            }
            values.append(early)
            return values
        }

        func pack(_ rows: [[Int]]) -> Plan? {
            budget -= 1
            var starts = [Date](repeating: .distantPast, count: tasks.count)
            var cursor = Date.distantPast
            var lastLesson = [Int](repeating: -1, count: courses.count)
            for d in days.indices {
                var window = 0
                for t in rows[d] {
                    let c = owners[t]
                    guard allowed[c][d] else { return nil }
                    if tasks[t].lessonID != nil {
                        guard t > lastLesson[c] else { return nil }
                        lastLesson[c] = t
                    }
                    let seconds = Double(tasks[t].durationMinutes * 60)
                    while window < days[d].windows.count {
                        let span = days[d].windows[window]
                        if max(cursor, span.start).addingTimeInterval(seconds) <= span.end { break }
                        window += 1
                    }
                    guard window < days[d].windows.count else { return nil }
                    starts[t] = max(cursor, days[d].windows[window].start)
                    cursor = starts[t].addingTimeInterval(seconds + rest)
                }
            }
            return .init(rows: rows, starts: starts, score: score(rows: rows, starts: starts))
        }

        /// A complete pacing candidate can cross a local plateau that moving a
        /// single ordered lesson cannot: for example, spreading a ten-lesson queue
        /// over five days requires several later lessons to move together.
        func redistributed() -> [[Int]] {
            let queues = courses.indices.map { c in tasks.indices.filter { owners[$0] == c } }
            var positions = [Int](repeating: 0, count: courses.count)
            var rows = [[Int]](repeating: [], count: days.count)
            var suffix = [Int](repeating: 0, count: days.count + 1)
            for d in days.indices.reversed() {
                suffix[d] = suffix[d + 1] + (courses.indices.contains { c in
                    allowed[c][d] && queues[c].contains { t in days[d].windows.contains {
                        $0.end.timeIntervalSince($0.start) >= Double(tasks[t].durationMinutes * 60)
                    } }
                } ? 1 : 0)
            }
            var remaining = tasks.reduce(0) { $0 + $1.durationMinutes }
            var cursor = Date.distantPast
            for d in days.indices {
                let quota = Double(remaining) / Double(max(1, suffix[d]))
                var total = 0, daily = [Int](repeating: 0, count: courses.count), window = 0
                while window < days[d].windows.count {
                    var candidates: [Int] = []
                    for c in courses.indices where allowed[c][d] && positions[c] < queues[c].count {
                        let t = queues[c][positions[c]], span = days[d].windows[window]
                        if max(cursor, span.start).addingTimeInterval(Double(tasks[t].durationMinutes * 60)) <= span.end { candidates.append(c) }
                    }
                    if candidates.isEmpty { window += 1; continue }
                    let urgent = candidates.filter { d == allowed[$0].lastIndex(of: true) }
                    if !urgent.isEmpty { candidates = urgent }
                    else if Double(total) >= quota { break }
                    let chosen = candidates.min { a, b in
                        if (daily[a] == 0) != (daily[b] == 0) { return daily[a] == 0 }
                        if daily[a] != daily[b] { return daily[a] < daily[b] }
                        let progressA = Double(positions[a]) / Double(max(1, queues[a].count))
                        let progressB = Double(positions[b]) / Double(max(1, queues[b].count))
                        if progressA != progressB { return progressA < progressB }
                        return a < b
                    }!
                    let t = queues[chosen][positions[chosen]], size = tasks[t].durationMinutes
                    if urgent.isEmpty && total > 0 && Double(total) + Double(size) / 2 > quota { break }
                    rows[d].append(t); positions[chosen] += 1
                    daily[chosen] += size; total += size; remaining -= size
                    cursor = max(cursor, days[d].windows[window].start).addingTimeInterval(Double(size * 60) + rest)
                }
            }
            return remaining == 0 ? rows : initialRows
        }

        func interleaved(_ rows: [[Int]]) -> [[Int]] {
            // Intra-day load and boost scores do not depend on order. Only diversity
            // and priority compete here, in the same saved order as the plan score.
            let diversityFirst = priorities.orderedRules.firstIndex(of: .diversity)!
                < priorities.orderedRules.firstIndex(of: .coursePriority)!
            return rows.map { row in
                var queues = courses.indices.map { c in row.filter { owners[$0] == c } }
                var output: [Int] = [], present = Set<Int>(), previous: Int?
                while output.count < row.count {
                    let candidates = courses.indices.filter { !queues[$0].isEmpty }
                    let chosen = candidates.min { a, b in
                        if !diversityFirst && courses[a].priority != courses[b].priority { return courses[a].priority > courses[b].priority }
                        if present.contains(a) != present.contains(b) { return !present.contains(a) }
                        if (previous == a) != (previous == b) { return previous != a }
                        if courses[a].priority != courses[b].priority { return courses[a].priority > courses[b].priority }
                        return queues[a][0] < queues[b][0]
                    }!
                    output.append(queues[chosen].removeFirst()); present.insert(chosen); previous = chosen
                }
                return output
            }
        }

        struct BeamKey: Hashable {
            var positions: [Int]
            var day: Int
            var mask: Int
            var previous: Int
        }
        struct BeamNode {
            var key: BeamKey
            var end: Int
            var task: Int
            var start: Int
            var parent: Int
            var coverage: Double
            var earlyCoverage: Double
            var repetitions: Double
            var rank: [Double]
        }

        func needsQueueReconstruction(_ plan: Plan) -> Bool {
            guard courses.count >= 2, tasks.count >= 20, days.count >= 7,
                  Set(tasks.map(\.durationMinutes)).count >= 3 else { return false }
            var lastDay = [Int](repeating: -1, count: courses.count)
            for d in days.indices { for t in plan.rows[d] { lastDay[owners[t]] = d } }
            return days.indices.contains { d in
                let available = courses.indices.filter { allowed[$0][d] && lastDay[$0] >= d }.count
                return Set(plan.rows[d].map { owners[$0] }).count < min(3, available)
            }
        }

        func rankPrecedes(_ a: [Double], _ b: [Double]) -> Bool {
            for (x, y) in zip(a, b) where x != y { return x < y }
            return false
        }

        /// Keep several complete queue prefixes alive. A short-term preference
        /// must not discard the only prefix that can still finish a long course.
        /// This constructs an alternative; the normal whole-plan score decides
        /// whether it replaces the existing feasible timetable.
        func queueBeam(paceFirst: Bool) -> Plan? {
            guard courses.count <= 6, tasks.count <= 600, days.count <= 366 else { return nil }
            let queues = courses.indices.map { c in tasks.indices.filter { owners[$0] == c } }
            let windows = days.indices.flatMap { d in days[d].windows.map {
                (start: Int(ceil($0.start.timeIntervalSinceReferenceDate / 60)), end: Int(floor($0.end.timeIntervalSinceReferenceDate / 60)), day: d)
            } }
            guard !windows.isEmpty, windows.count <= 1500 else { return nil }
            let beamWidth = min(32, max(4, 60_000 / max(1, tasks.count * courses.count)))
            let rest = ScheduleEngine.breakMinutes
            var suffix: [[Int]] = [], latest: [[Int]] = [], totalCapacity: [Int] = []
            for c in courses.indices {
                var sums = [Int](repeating: 0, count: queues[c].count + 1)
                var last = [Int](repeating: Int.max / 4, count: queues[c].count + 1)
                var end = windows.last!.end
                for p in queues[c].indices.reversed() {
                    let size = tasks[queues[c][p]].durationMinutes
                    guard let w = windows.last(where: { allowed[c][$0.day] && min(end, $0.end) - size >= $0.start }) else { return nil }
                    last[p] = min(end, w.end) - size; end = last[p] - rest
                    sums[p] = sums[p + 1] + size
                }
                suffix.append(sums); latest.append(last)
                totalCapacity.append(windows.filter { allowed[c][$0.day] }.reduce(0) { $0 + $1.end - $1.start })
            }
            let deadlines = Set(courses.indices.compactMap { allowed[$0].lastIndex(of: true) }).sorted()
            func assessment(_ key: BeamKey, _ end: Int) -> Double? {
                for c in courses.indices where key.positions[c] < queues[c].count {
                    if end + rest > latest[c][key.positions[c]] { return nil }
                }
                for cutoff in deadlines {
                    let group = courses.indices.filter { (allowed[$0].lastIndex(of: true) ?? -1) <= cutoff }
                    let required = group.reduce(0) { $0 + suffix[$1][key.positions[$1]] }
                    let blocks = group.reduce(0) { $0 + queues[$1].count - key.positions[$1] }
                    var capacity = 0, regions = 0
                    for w in windows where w.day <= cutoff && w.end > end {
                        capacity += w.end - max(end, w.start); regions += 1
                    }
                    if required + rest * max(0, blocks - regions) > capacity { return nil }
                }
                var pace = 0.0
                for c in courses.indices where suffix[c][0] > 0 {
                    let used = windows.filter { allowed[c][$0.day] && $0.start < end }
                        .reduce(0) { $0 + max(0, min(end, $1.end) - $1.start) }
                    let expected = min(1, Double(used) / Double(max(1, totalCapacity[c])) * courses[c].dailyWeight)
                    let completed = Double(suffix[c][0] - suffix[c][key.positions[c]]) / Double(suffix[c][0])
                    pace += (completed - expected) * (completed - expected)
                }
                return pace
            }
            let first = BeamKey(positions: courses.map { _ in 0 }, day: -1, mask: 0, previous: -1)
            var nodes = [BeamNode(key: first, end: windows[0].start - rest, task: -1, start: 0, parent: -1,
                                  coverage: 0, earlyCoverage: 0, repetitions: 0, rank: [])]
            var beam = [0], expansions = 0
            for _ in tasks.indices {
                var candidates: [BeamKey: BeamNode] = [:]
                for parent in beam {
                    let previous = nodes[parent]
                    for c in courses.indices where previous.key.positions[c] < queues[c].count {
                        expansions += 1
                        if expansions > 60_000 { return nil }
                        let t = queues[c][previous.key.positions[c]], size = tasks[t].durationMinutes
                        guard let w = windows.first(where: { allowed[c][$0.day] && max(previous.end + rest, $0.start) + size <= $0.end }) else { continue }
                        let start = max(previous.end + rest, w.start), end = start + size
                        var key = previous.key
                        key.positions[c] += 1
                        if key.day != w.day { key.day = w.day; key.mask = 0; key.previous = -1 }
                        let count = min(3, key.mask.nonzeroBitCount)
                        let gain = key.mask & (1 << c) == 0 && count < 3 ? Double(count) : 0
                        let repetitions = previous.repetitions + (key.previous == c ? 1 : 0)
                        key.mask |= 1 << c; key.previous = c
                        guard let pace = assessment(key, end) else { continue }
                        let coverage = previous.coverage + gain
                        let earlyCoverage = previous.earlyCoverage + gain * Double(days.count - w.day)
                        let rank = paceFirst ? [pace, -coverage, -earlyCoverage, repetitions, Double(end)]
                            : [-coverage, -earlyCoverage, pace, repetitions, Double(end)]
                        if let old = candidates[key], !rankPrecedes(rank, old.rank) { continue }
                        candidates[key] = .init(key: key, end: end, task: t, start: start, parent: parent,
                                                coverage: coverage, earlyCoverage: earlyCoverage, repetitions: repetitions, rank: rank)
                    }
                }
                guard !candidates.isEmpty else { return nil }
                let selected = candidates.values.sorted { a, b in
                    if rankPrecedes(a.rank, b.rank) { return true }
                    if rankPrecedes(b.rank, a.rank) { return false }
                    if a.key.positions != b.key.positions { return a.key.positions.lexicographicallyPrecedes(b.key.positions) }
                    if a.key.day != b.key.day { return a.key.day < b.key.day }
                    if a.key.mask != b.key.mask { return a.key.mask < b.key.mask }
                    return a.key.previous < b.key.previous
                }.prefix(beamWidth)
                beam = []
                for node in selected { beam.append(nodes.count); nodes.append(node) }
            }
            var best: Plan?
            for final in beam {
                var rows = [[Int]](repeating: [], count: days.count)
                var starts = [Date](repeating: .distantPast, count: tasks.count), index = final
                while nodes[index].parent >= 0 {
                    let node = nodes[index]
                    rows[node.key.day].append(node.task)
                    starts[node.task] = Date(timeIntervalSinceReferenceDate: Double(node.start) * 60)
                    index = node.parent
                }
                for d in days.indices { rows[d].reverse() }
                let result = Plan(rows: rows, starts: starts, score: score(rows: rows, starts: starts))
                if best == nil || better(result.score, than: best!.score) { best = result }
            }
            return best
        }

        /// Destroy/repair a short run of days. Ordered queues may move together;
        /// tasks outside the run keep their exact starts. Every accepted leaf is
        /// scored by the same whole-plan objective, with no preference relaxation.
        func jointNeighborhoods(_ incumbent: Plan) -> Plan {
            guard tasks.count <= 600, courses.count <= 6, days.count <= 366 else { return incumbent }
            var best = incumbent
            let large = tasks.count > 24 || days.count > 7
            var remainingEvaluations = min(large ? 6_000 : 40_000, 6_000_000 / max(1, tasks.count + days.count * courses.count))
            var remainingLeaves = min(large ? 300 : 2_000, 600_000 / max(1, tasks.count + days.count * courses.count))
            for width in [4, 3, 2, 1] where width <= days.count {
                for first in 0...(days.count - width) {
                    if remainingEvaluations <= 0 || remainingLeaves <= 0 { return best }
                    let last = first + width - 1
                    let selected = Array(best.rows[first...last].joined())
                    guard (3...12).contains(selected.count), Set(selected.map { owners[$0] }).count <= 4 else { continue }
                    let queues = courses.indices.map { c in selected.filter { owners[$0] == c } }
                    var positions = courses.map { _ in 0 }
                    let before = best.rows.prefix(first).joined().last
                    let after = best.rows.dropFirst(last + 1).joined().first
                    let floor = before.map { best.starts[$0].addingTimeInterval(Double(tasks[$0].durationMinutes * 60) + rest) } ?? .distantPast
                    let ceiling = after.map { best.starts[$0].addingTimeInterval(-rest) } ?? .distantFuture
                    var rows = best.rows, starts = best.starts
                    for d in first...last { rows[d] = [] }
                    var suffix = [[Int]](), shortestSuffix = [[Int]](), latest = [[Date]]()
                    var possible = true
                    for c in courses.indices {
                        var sums = [Int](repeating: 0, count: queues[c].count + 1)
                        var shortest = [Int](repeating: Int.max, count: queues[c].count + 1)
                        var limits = [Date](repeating: .distantFuture, count: queues[c].count + 1)
                        var end = ceiling
                        for p in queues[c].indices.reversed() {
                            let size = Double(tasks[queues[c][p]].durationMinutes * 60)
                            var found: Date?
                            for d in (first...last).reversed() where allowed[c][d] {
                                if let span = days[d].windows.last(where: { min(end, $0.end).addingTimeInterval(-size) >= max(floor, $0.start) }) {
                                    found = min(end, span.end).addingTimeInterval(-size); break
                                }
                            }
                            guard let found else { possible = false; break }
                            limits[p] = found; end = found.addingTimeInterval(-rest)
                            sums[p] = sums[p + 1] + tasks[queues[c][p]].durationMinutes
                            shortest[p] = min(shortest[p + 1], tasks[queues[c][p]].durationMinutes)
                        }
                        suffix.append(sums); shortestSuffix.append(shortest); latest.append(limits)
                    }
                    guard possible else { continue }
                    var localEvaluations = min(large ? 1_500 : 12_000, remainingEvaluations)

                    // Relaxed optimistic bounds only prune; they never decide which
                    // actual plan wins. Missing work may appear independently on
                    // several days in this bound, so it overestimates opportunity.
                    func lowerBound(_ ready: Date) -> [Double] {
                        remainingEvaluations -= 1; localEvaluations -= 1
                        var bound = score(rows: rows, starts: starts)
                        var loads = courses.map { _ in [Double](repeating: 0, count: days.count) }
                        for d in days.indices { for t in rows[d] { loads[owners[t]][d] += Double(tasks[t].durationMinutes) } }
                        var coverage = 0.0, earlyCoverage = 0.0, boost = 0.0, triple = 0.0
                        for d in days.indices {
                            var present = 0
                            for c in courses.indices {
                                let left = suffix[c][positions[c]]
                                let shortest = shortestSuffix[c][positions[c]]
                                let canAdd = left > 0 && (first...last).contains(d) && allowed[c][d]
                                    && days[d].windows.contains { max(ready, $0.start).addingTimeInterval(Double(shortest * 60)) <= min(ceiling, $0.end) }
                                if loads[c][d] > 0 || canAdd { present += 1 }
                                if courses[c].dailyWeight > 1 {
                                    let low = loads[c][d], high = low + (canAdd ? Double(left) : 0)
                                    let target = targets[c][d]
                                    let difference = target < low ? low - target : max(0, target - high)
                                    boost += difference * difference
                                    if courses[c].dailyWeight == 3 { triple += difference * difference }
                                }
                            }
                            let count = Double(min(3, present)), value = count * (count - 1) / 2
                            coverage += value; earlyCoverage += value * Double(days.count - d)
                        }
                        var offset = 0
                        if priorities.usesDefaultOrder { bound[0] = triple; offset = 1 }
                        for rule in priorities.orderedRules {
                            switch rule {
                            case .diversity: bound[offset] = -coverage; bound[offset + 1] = -earlyCoverage; offset += 3
                            case .dailyWeight: bound[offset] = boost; offset += 1
                            case .coursePriority: offset += 1
                            case .balancedLoad: offset += 2
                            }
                        }
                        return bound
                    }
                    struct Choice { var course: Int; var day: Int; var start: Date; var bound: [Double] }
                    func visit(_ ready: Date, _ placed: Int) {
                        guard remainingEvaluations > 0, localEvaluations > 0, remainingLeaves > 0 else { return }
                        if placed == selected.count {
                            remainingLeaves -= 1
                            let value = score(rows: rows, starts: starts)
                            if better(value, than: best.score) { best = .init(rows: rows, starts: starts, score: value) }
                            return
                        }
                        var required = 0, blocks = 0
                        for c in courses.indices where positions[c] < queues[c].count {
                            if ready > latest[c][positions[c]] { return }
                            required += suffix[c][positions[c]]; blocks += queues[c].count - positions[c]
                        }
                        var capacity = 0.0, regions = 0
                        for d in first...last { for span in days[d].windows {
                            let size = min(ceiling, span.end).timeIntervalSince(max(ready, span.start)) / 60
                            if size > 0 { capacity += size; regions += 1 }
                        } }
                        if Double(required + ScheduleEngine.breakMinutes * max(0, blocks - regions)) > capacity { return }
                        if !better(lowerBound(ready), than: best.score) { return }
                        var choices: [Choice] = []
                        choiceGeneration: for c in courses.indices where positions[c] < queues[c].count {
                            let t = queues[c][positions[c]], seconds = Double(tasks[t].durationMinutes * 60)
                            for d in first...last where allowed[c][d] {
                                if remainingEvaluations <= 0 || localEvaluations <= 0 { break choiceGeneration }
                                guard let span = days[d].windows.first(where: { max(ready, $0.start).addingTimeInterval(seconds) <= min(ceiling, $0.end) }) else { continue }
                                let start = max(ready, span.start), next = start.addingTimeInterval(seconds + rest)
                                rows[d].append(t); starts[t] = start; positions[c] += 1
                                choices.append(.init(course: c, day: d, start: start, bound: lowerBound(next)))
                                positions[c] -= 1; rows[d].removeLast()
                            }
                        }
                        choices.sort {
                            if rankPrecedes($0.bound, $1.bound) { return true }
                            if rankPrecedes($1.bound, $0.bound) { return false }
                            if $0.day != $1.day { return $0.day < $1.day }
                            return $0.course < $1.course
                        }
                        for choice in choices {
                            if remainingEvaluations <= 0 || localEvaluations <= 0 || remainingLeaves <= 0 { break }
                            if !better(choice.bound, than: best.score) { continue }
                            let c = choice.course, t = queues[c][positions[c]]
                            rows[choice.day].append(t); starts[t] = choice.start; positions[c] += 1
                            visit(choice.start.addingTimeInterval(Double(tasks[t].durationMinutes * 60) + rest), placed + 1)
                            positions[c] -= 1; rows[choice.day].removeLast()
                        }
                    }
                    visit(floor, 0)
                }
            }
            return best
        }

        func run() -> Outcome {
            let baseline = tasks.map(\.start)
            var current = Plan(rows: initialRows, starts: baseline, score: score(rows: initialRows, starts: baseline))
            // First-fit compaction in the same chronological order cannot make an
            // existing task finish later. Still compare it against the full objective.
            if let compact = pack(initialRows), better(compact.score, than: current.score) { current = compact }
            let paced = redistributed()
            for rows in [interleaved(current.rows), paced, interleaved(paced)] {
                if let trial = pack(rows), better(trial.score, than: current.score) { current = trial }
            }
            if needsQueueReconstruction(current) {
                for paceFirst in [false, true] {
                    if let trial = queueBeam(paceFirst: paceFirst), better(trial.score, than: current.score) { current = trial }
                }
            }
            if let trial = pack(interleaved(current.rows)), better(trial.score, than: current.score) { current = trial }
            var changed = true
            while changed && budget > 0 {
                changed = false
                // Reserve attempts for exchanges even when full days make all
                // one-way moves fail. Long horizons must not consume that budget first.
                let moveFloor = budget / 2
                // Relocate one block, including insertion at any point within a day.
                // Whole-lesson sequence is checked after every tentative placement.
                move: for source in days.indices {
                    for position in current.rows[source].indices {
                        let t = current.rows[source][position], c = owners[t]
                        for target in days.indices where allowed[c][target] {
                            let count = current.rows[target].count - (source == target ? 1 : 0)
                            for insertion in 0...count {
                                if budget <= moveFloor { break move }
                                if source == target && insertion == position { continue }
                                var rows = current.rows
                                rows[source].remove(at: position); rows[target].insert(t, at: insertion)
                                if let trial = pack(rows), better(trial.score, than: current.score) {
                                    current = trial; changed = true; break move
                                }
                            }
                        }
                    }
                }
                if changed { continue }
                // Full days need swaps: there may be no empty slot into which either
                // lesson could move alone. Unequal durations are repacked, never trimmed.
                swap: for a in days.indices {
                    for ai in current.rows[a].indices {
                        let first = current.rows[a][ai]
                        for b in a..<days.count {
                            for bi in current.rows[b].indices {
                                if a == b && bi <= ai { continue }
                                let second = current.rows[b][bi]
                                if owners[first] == owners[second] { continue }
                                if !allowed[owners[first]][b] || !allowed[owners[second]][a] { continue }
                                if budget <= 0 { break swap }
                                var rows = current.rows
                                rows[a][ai] = second; rows[b][bi] = first
                                if let trial = pack(rows), better(trial.score, than: current.score) {
                                    current = trial; changed = true; break swap
                                }
                            }
                        }
                    }
                }
            }
            current = jointNeighborhoods(current)
            var output = tasks
            for i in output.indices { output[i].start = current.starts[i] }
            return .init(tasks: output.sorted { $0.start < $1.start },
                         improved: better(current.score, than: score(rows: initialRows, starts: baseline)))
        }
    }
}
