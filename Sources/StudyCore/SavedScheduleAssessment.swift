import Foundation

extension ScheduleEngine {
    /// Evaluate the persisted timetable without substituting a newly generated draft.
    /// Full early confirmations preserve other slots, as do sync-only refreshes.
    public func assessSavedPlan(state: PlannerState, now: Date) -> ScheduleResult {
        var result = generate(state: state, now: now)
        let courses = state.courses.filter { !$0.isArchived && $0.autoScheduleEnabled && state.remainingMinutes(for: $0) > 0 }
        let ids = Set(courses.map(\.id))
        result.tasks = state.tasks.filter {
            $0.isUnconfirmed && $0.planningEnd > now && ids.contains($0.courseID)
        }.sorted { $0.start < $1.start }
        let booked = Dictionary(grouping: result.tasks, by: \.courseID)
            .mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }
        let missing = Dictionary(uniqueKeysWithValues: courses.map {
            ($0.id, max(0, state.remainingMinutes(for: $0) - booked[$0.id, default: 0]))
        })
        let daily = Dictionary(grouping: result.tasks, by: { calendar.startOfDay(for: $0.start) })
            .mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }
        for index in result.dayPlans.indices {
            result.dayPlans[index].plannedMinutes = daily[result.dayPlans[index].date, default: 0]
        }
        result.risks = Set(courses.map { calendar.startOfDay(for: $0.deadline) }).sorted().compactMap { cutoff in
            let group = courses.filter { calendar.startOfDay(for: $0.deadline) <= cutoff }
            let absent = group.reduce(0) { $0 + missing[$1.id, default: 0] }
            guard absent > 0 else { return nil }
            let capacity = result.dayPlans.filter { day in
                day.date <= cutoff && group.contains {
                    day.date >= calendar.startOfDay(for: $0.startDate) && day.date <= calendar.startOfDay(for: $0.deadline)
                }
            }.reduce(0) { $0 + $1.availableMinutes }
            return ScheduleRisk(deadline: cutoff,
                                requiredMinutes: group.reduce(0) { $0 + state.remainingMinutes(for: $1) },
                                availableMinutes: capacity, unscheduledMinutes: absent,
                                courseNames: group.filter { missing[$0.id, default: 0] > 0 }.map(\.name))
        }
        // A complete saved plan must not inherit a conflict or an adjustment
        // belonging only to the alternative draft that was never applied.
        let missingNames = Set(courses.filter { missing[$0.id, default: 0] > 0 }.map(\.name))
        result.conflicts.removeAll { Set($0.courseNames).isDisjoint(with: missingNames) }
        result.adjustments = []
        return result
    }
}
