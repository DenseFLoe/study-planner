import Foundation

/// A deterministic feasibility witness, never presented as an actual event time.
/// Each floating event occupies one continuous interval inside its window.
enum FloatingPlacement {
    static func reserve(_ events: [FixedEvent], studyMinutes: Set<Int> = []) -> [UUID: Int]? {
        guard events.allSatisfy({ $0.startMinute >= 0 && $0.endMinute <= 1440 && $0.startMinute < $0.endMinute && $0.validDuration }) else { return nil }
        var busy = [Bool](repeating: false, count: 1440)
        for event in events where !event.isFloating {
            for minute in event.startMinute..<event.endMinute { busy[minute] = true }
        }
        let floating = events.filter(\.isFloating).sorted {
            let a = $0.endMinute - $0.startMinute - $0.occupiedMinutes
            let b = $1.endMinute - $1.startMinute - $1.occupiedMinutes
            return a != b ? a < b : $0.id.uuidString < $1.id.uuidString
        }
        // Prefer complete placements with the least overlap with study availability.
        // Search jointly: choosing a cheap position for one event can block another.
        var prefix = [Int](repeating: 0, count: 1441)
        for minute in 0..<1440 {
            prefix[minute + 1] = prefix[minute] + (studyMinutes.contains(minute) && !busy[minute] ? 1 : 0)
        }
        let candidates = floating.map { event in
            (event.startMinute...(event.endMinute - event.occupiedMinutes)).map { start in
                (start: start, cost: prefix[start + event.occupiedMinutes] - prefix[start])
            }.sorted { $0.cost != $1.cost ? $0.cost < $1.cost : $0.start > $1.start }
        }
        var lowerBound = [Int](repeating: 0, count: floating.count + 1)
        for index in floating.indices.reversed() {
            lowerBound[index] = lowerBound[index + 1] + candidates[index][0].cost
        }
        var placements: [UUID: Int] = [:], best: [UUID: Int]?
        var bestCost = Int.max
        var attempts = 0
        func search(_ index: Int, cost: Int) {
            guard cost + lowerBound[index] < bestCost, attempts < 20_000 else { return }
            if index == floating.count { best = placements; bestCost = cost; return }
            let event = floating[index]
            for candidate in candidates[index] {
                if cost + candidate.cost + lowerBound[index + 1] >= bestCost || attempts >= 20_000 { break }
                attempts += 1
                let start = candidate.start
                let range = start..<(start + event.occupiedMinutes)
                if range.contains(where: { busy[$0] }) { continue }
                for m in range { busy[m] = true }
                placements[event.id] = start
                search(index + 1, cost: cost + candidate.cost)
                placements.removeValue(forKey: event.id)
                for m in range { busy[m] = false }
            }
        }
        search(0, cost: 0)
        // If optimization hits its budget, retain the best feasible arrangement found.
        return best
    }
}
