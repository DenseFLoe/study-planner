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
            var output = tasks
            for i in output.indices { output[i].start = current.starts[i] }
            return .init(tasks: output.sorted { $0.start < $1.start },
                         improved: better(current.score, than: score(rows: initialRows, starts: baseline)))
        }
    }
}
