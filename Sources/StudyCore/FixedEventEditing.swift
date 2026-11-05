import Foundation

public enum FixedEventEditError: LocalizedError {
    case removed, conflictingChanges, reviewChanged, removalChanged, occurrenceChanged

    public var errorDescription: String? {
        switch self {
        case .removed: "这条固定事项已被删除，旧编辑窗口不能重新创建它。草稿仍保留，请关闭窗口后查看最新事项。"
        case .conflictingChanges: "这条固定事项在编辑期间已有其他修改，与当前草稿冲突。草稿仍保留，最新数据未被覆盖，请重新打开事项后编辑。"
        case .reviewChanged: "冲突安排已发生变化，原来的跳过选择未保存。请返回修改后重新检查冲突。"
        case .removalChanged: "这条固定事项在确认删除前已更新，未执行删除。请重新查看最新规则后再确认。"
        case .occurrenceChanged: "这一天的固定事项已更新，未移除或恢复旧安排。请重新查看当天时段后再操作。"
        }
    }
}

public struct FixedEventOccurrenceEdit: Sendable {
    public let reviewed: FixedEvent
    public let day: Date
    public let skipped: Bool
    /// Consent to skip only these reviewed occupants while restoring this day.
    public let reviewedConflicts: [FixedEventConflict]?
    public init(reviewed: FixedEvent, on day: Date, skipped: Bool,
                reviewedConflicts: [FixedEventConflict]? = nil) {
        self.reviewed = reviewed; self.day = day; self.skipped = skipped
        self.reviewedConflicts = reviewedConflicts
    }
    public func apply(to state: inout PlannerState, now: Date, calendar: Calendar = .current) throws {
        guard !skipped || reviewedConflicts == nil else { throw FixedEventEditError.reviewChanged }
        guard let current = state.fixedEvents.first(where: { $0.id == reviewed.id }),
              current.title == reviewed.title, current.startMinute == reviewed.startMinute,
              current.endMinute == reviewed.endMinute, current.floatingDurationMinutes == reviewed.floatingDurationMinutes,
              current.occurs(on: day, calendar: calendar, includingExcluded: true),
              reviewed.occurs(on: day, calendar: calendar, includingExcluded: true)
        else { throw FixedEventEditError.occurrenceChanged }
        var next = state
        do {
            try next.setFixedEventSkipped(id: reviewed.id, on: day, skipped: skipped, now: now, calendar: calendar)
        } catch let PlannerError.fixedConflict(conflicts) {
            guard let reviewedConflicts, conflicts == reviewedConflicts else {
                throw PlannerError.fixedConflict(conflicts)
            }
            let date = calendar.startOfDay(for: day)
            guard !conflicts.isEmpty, conflicts.allSatisfy({ $0.date == date && $0.reason != .activeTask }) else {
                throw FixedEventEditError.reviewChanged
            }
            // Recheck before changing any exclusions, and publish both sides
            // together. Never split the recurring rule or cancel another day.
            for conflict in conflicts {
                try next.setFixedEventSkipped(id: conflict.eventID, on: date, skipped: true, now: now, calendar: calendar)
            }
            try next.setFixedEventSkipped(id: reviewed.id, on: date, skipped: false, now: now, calendar: calendar)
        }
        // If the conflict has disappeared (or another peer already restored the
        // occurrence), no reviewed occupant needs to be skipped.
        state = next
    }
}

public extension PlannerState {
    mutating func removeFixedEvent(reviewed: FixedEvent) throws {
        guard let current = fixedEvents.first(where: { $0.id == reviewed.id }) else { throw FixedEventEditError.removed }
        guard current == reviewed else { throw FixedEventEditError.removalChanged }
        removeFixedEvent(id: reviewed.id)
    }
}

public extension FixedEvent {
    /// A recurrence, its window and its exceptions describe one coherent rule.
    func hasSameSchedulingInputs(as other: FixedEvent) -> Bool {
        startMinute == other.startMinute && endMinute == other.endMinute &&
        startDate == other.startDate && endDate == other.endDate && weekdays == other.weekdays &&
        excludedDates == other.excludedDates && floatingDurationMinutes == other.floatingDurationMinutes
    }

    func mergingDraft(from baseline: FixedEvent, into current: FixedEvent) throws -> FixedEvent {
        guard id == baseline.id, id == current.id else { throw FixedEventEditError.conflictingChanges }
        var merged: FixedEvent
        if hasSameSchedulingInputs(as: baseline) {
            merged = current
        } else if current.hasSameSchedulingInputs(as: baseline) || hasSameSchedulingInputs(as: current) {
            merged = self
        } else { throw FixedEventEditError.conflictingChanges }
        func field(_ edited: String, _ old: String, _ latest: String) throws -> String {
            if edited == old { return latest }
            guard latest == old || latest == edited else { throw FixedEventEditError.conflictingChanges }
            return edited
        }
        merged.title = try field(title, baseline.title, current.title)
        merged.notes = try field(notes, baseline.notes, current.notes)
        merged.color = try field(color, baseline.color, current.color)
        return merged
    }
}

/// Keep the editor's original baseline through conflict review and the final
/// optimistic transaction. Reapply the intent to the latest state before splitting
/// historical rules, generating IDs, skipping occurrences or scheduling tasks.
public struct FixedEventEdit: Sendable {
    public var event: FixedEvent
    public var baseline: FixedEvent?
    public var skippingDates: Set<Date>
    public var skippingExistingDates: Set<Date>
    public var reviewedConflicts: [FixedEventConflict]?

    public init(event: FixedEvent, baseline: FixedEvent?, skippingDates: Set<Date> = [],
                skippingExistingDates: Set<Date> = [], reviewedConflicts: [FixedEventConflict]? = nil) {
        self.event = event; self.baseline = baseline
        self.skippingDates = skippingDates; self.skippingExistingDates = skippingExistingDates
        self.reviewedConflicts = reviewedConflicts
    }

    public func apply(to state: inout PlannerState, now: Date, calendar: Calendar = .current) throws {
        let current = state.fixedEvents.first { $0.id == event.id }
        let resolved: FixedEvent
        if let baseline {
            guard let current else { throw FixedEventEditError.removed }
            resolved = try event.mergingDraft(from: baseline, into: current)
        } else {
            guard current == nil else { throw FixedEventEditError.conflictingChanges }
            resolved = event
        }
        if let reviewedConflicts {
            var probe = state
            var conflicts: [FixedEventConflict] = []
            do { try probe.updateFixedEvent(resolved, now: now, calendar: calendar) }
            catch let PlannerError.fixedConflict(found) { conflicts = found }
            guard conflicts == reviewedConflicts else {
                if conflicts.isEmpty { throw FixedEventEditError.reviewChanged }
                throw PlannerError.fixedConflict(conflicts)
            }
        } else if !skippingDates.isEmpty || !skippingExistingDates.isEmpty {
            // Skipping is consent to the reviewed list, never to unseen occupants.
            throw FixedEventEditError.reviewChanged
        }
        var next = state
        try next.updateFixedEvent(resolved, now: now, calendar: calendar,
                                  skippingDates: skippingDates, skippingExistingDates: skippingExistingDates)
        state = next
    }
}
