import Observation
import StudyCore

/// Owned by the store, so rebuilding a navigation page cannot discard edits.
/// This is an in-memory draft; only the explicit Save action changes the plan.
@MainActor @Observable
final class SettingsDraft {
    var settings = AppSettings() { didSet { saved = false } }
    private(set) var baseline: AppSettings?
    private(set) var saved = false

    var hasChanges: Bool {
        baseline.map { !settings.hasSameEditableSettings(as: $0) } ?? false
    }

    func refresh(from current: AppSettings) {
        guard !hasChanges else { return }
        restore(from: current)
    }

    func restore(from current: AppSettings) {
        baseline = current
        settings = current
    }

    @discardableResult
    func save(using store: PlannerStore) async -> Bool {
        guard let baseline else { return false }
        let success = await store.saveStudySettings(settings, from: baseline)
        if success {
            restore(from: store.state.settings)
            saved = true
        }
        return success
    }
}
