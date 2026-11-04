import Foundation

public enum FixedEventEditError: LocalizedError {
    case removed, conflictingChanges, reviewChanged

    public var errorDescription: String? {
        switch self {
        case .removed: "这条固定事项已被删除，旧编辑窗口不能重新创建它。草稿仍保留，请关闭窗口后查看最新事项。"
        case .conflictingChanges: "这条固定事项在编辑期间已有其他修改，与当前草稿冲突。草稿仍保留，最新数据未被覆盖，请重新打开事项后编辑。"
        case .reviewChanged: "冲突安排已发生变化，原来的跳过选择未保存。请返回修改后重新检查冲突。"
        }
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
