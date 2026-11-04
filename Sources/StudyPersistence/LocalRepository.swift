import Foundation
import SwiftData
import StudyCore

/// Local business rows and the sync ledger share a single SwiftData transaction.
@Model
final class LocalRecord {
    var key: String = ""
    var kind: String = ""
    var payload: Data = Data()
    init(key: String, kind: String, payload: Data) {
        self.key = key; self.kind = kind; self.payload = payload
    }
}

public protocol PlannerRepository {
    func load() throws -> PlannerState
    func save(_ state: PlannerState) throws
    @MainActor func saveForInteraction(_ state: PlannerState) async throws
    func saveChanges(_ state: PlannerState, from baseline: PlannerState) throws -> PlannerState
    @MainActor func saveChangesForInteraction(_ state: PlannerState, from baseline: PlannerState) async throws -> PlannerState
    @MainActor func saveFixedEventForInteraction(_ edit: FixedEventEdit,
                                               from baseline: PlannerState, now: Date) async throws -> PlannerState
    @MainActor func saveFixedOccurrenceForInteraction(_ edit: FixedEventOccurrenceEdit,
                                                     from baseline: PlannerState, now: Date) async throws -> PlannerState
    @MainActor func saveLessonOrderForInteraction(_ draft: LessonOrderDraft,
                                                from baseline: PlannerState, now: Date) async throws -> PlannerState
}

extension PlannerRepository {
    @MainActor public func saveFixedOccurrenceForInteraction(_ edit: FixedEventOccurrenceEdit,
                                                            from baseline: PlannerState, now: Date) async throws -> PlannerState {
        var next = baseline
        try edit.apply(to: &next, now: now)
        if next != baseline { _ = next.replan(now: now) }
        return try await saveChangesForInteraction(next, from: baseline)
    }
    @MainActor public func saveForInteraction(_ state: PlannerState) async throws { try save(state) }
    public func saveChanges(_ state: PlannerState, from baseline: PlannerState) throws -> PlannerState {
        try save(state)
        return state
    }
    @MainActor public func saveChangesForInteraction(_ state: PlannerState, from baseline: PlannerState) async throws -> PlannerState {
        try await saveForInteraction(state)
        return state
    }
    @MainActor public func saveFixedEventForInteraction(_ edit: FixedEventEdit,
                                                       from baseline: PlannerState, now: Date) async throws -> PlannerState {
        var next = baseline
        try edit.apply(to: &next, now: now)
        _ = next.replan(now: now)
        return try await saveChangesForInteraction(next, from: baseline)
    }
    @MainActor public func saveLessonOrderForInteraction(_ draft: LessonOrderDraft,
                                                        from baseline: PlannerState, now: Date) async throws -> PlannerState {
        var next = baseline
        try draft.apply(to: &next)
        if next != baseline { _ = next.replan(now: now) }
        return try await saveChangesForInteraction(next, from: baseline)
    }
}

public final class LocalRepository: PlannerRepository {
    private static let transactionLock = NSRecursiveLock()
    /// Serialize local read/modify/write transactions with background sync.
    /// Network transfers and schedule calculations never hold this lock.
    public static func withExclusiveAccess<T>(_ operation: () throws -> T) rethrows -> T {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return try operation()
    }
    private let container: ModelContainer
    private var context: ModelContext
    private let encoder: JSONEncoder
    private let migrationBackupURL: URL?
    private let cloudOutboxURL: URL?
    private struct SettingsPayload: Codable {
        var version: Int
        var settings: AppSettings
    }
    public init(inMemory: Bool = false, url: URL? = nil) throws {
        let configuration: ModelConfiguration
        if let url {
            migrationBackupURL = nil
            cloudOutboxURL = nil
            configuration = ModelConfiguration("StudyPlanner", url: url, cloudKitDatabase: .none)
        } else if inMemory {
            migrationBackupURL = nil
            cloudOutboxURL = nil
            configuration = ModelConfiguration("StudyPlanner", isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("StudyPlanner", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            migrationBackupURL = directory.appendingPathComponent("before-local-sync.json")
            cloudOutboxURL = directory.appendingPathComponent("CloudOutbox", isDirectory: true)
            configuration = ModelConfiguration("StudyPlanner", url: directory.appendingPathComponent("StudyPlanner.store"), cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: LocalRecord.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    }
    private init(container: ModelContainer, migrationBackupURL: URL?, cloudOutboxURL: URL?) {
        self.container = container
        self.migrationBackupURL = migrationBackupURL
        self.cloudOutboxURL = cloudOutboxURL
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    @MainActor public func saveForInteraction(_ state: PlannerState) async throws {
        let container = container
        let backup = migrationBackupURL
        let outbox = cloudOutboxURL
        // A fresh context stays on the worker; UI models never cross threads.
        try await Task.detached(priority: .userInitiated) {
            let worker = LocalRepository(container: container, migrationBackupURL: backup, cloudOutboxURL: outbox)
            try worker.save(state)
        }.value
        // Discard registered objects so the next UI transaction sees the new rows.
        discardCachedModels()
    }

    public func saveChanges(_ state: PlannerState, from baseline: PlannerState) throws -> PlannerState {
        try update { latest, ledger in
            try ledger.captureChanges(from: baseline, to: state)
            var merged = try ledger.materialize()
            // Fetch order is not a revision. Only unseen business-row changes
            // require repairing the combination of local and remote drafts.
            func sameRows<T: Identifiable & Equatable>(_ a: [T], _ b: [T]) -> Bool {
                Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) })
            }
            if latest.settings != baseline.settings || !sameRows(latest.courses, baseline.courses)
                || !sameRows(latest.fixedEvents, baseline.fixedEvents) || !sameRows(latest.tasks, baseline.tasks)
                || !sameRows(latest.completions, baseline.completions) {
                merged.reconcileSavedSchedule(now: Date())
            }
            // Materialization sorts by sync keys. Preserve displayed ordering so
            // an ordinary save does not appear to be a different plan and trigger
            // another expensive assessment on the main actor.
            func ordered<T: Identifiable>(_ values: [T], like reference: [T]) -> [T] {
                var remaining = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
                let known = reference.compactMap { remaining.removeValue(forKey: $0.id) }
                return known + values.filter { remaining[$0.id] != nil }
            }
            merged.courses = ordered(merged.courses, like: state.courses)
            merged.fixedEvents = ordered(merged.fixedEvents, like: state.fixedEvents)
            merged.tasks = ordered(merged.tasks, like: state.tasks)
            merged.completions = ordered(merged.completions, like: state.completions)
            latest = merged
            return merged
        }
    }

    /// Optimistic read/compute/commit. The closure must have no external side
    /// effects: a concurrent local/sync write causes it to run again. Scheduling
    /// stays outside the transaction lock, and state plus ledger commit together.
    public func update<T>(enqueueCloud: Bool = true,
                          _ operation: (inout PlannerState, inout SyncLedger) throws -> T) throws -> T {
        while true {
            let (snapshot, original) = try Self.withExclusiveAccess {
                context = ModelContext(container); context.autosaveEnabled = false
                try backupBeforeMigrationIfNeeded()
                let state = try load()
                var ledger = try loadLedger()
                if ledger.records.isEmpty {
                    try save(state, ledger: ledger)
                    ledger = try loadLedger()
                }
                return (state, ledger)
            }
            let token = try encoder.encode(original)
            var state = snapshot, ledger = original
            try ledger.capture(state)
            let result = try operation(&state, &ledger)
            let committed = try Self.withExclusiveAccess {
                context = ModelContext(container); context.autosaveEnabled = false
                guard try encoder.encode(loadLedger()) == token else { return false }
                try save(state, ledger: ledger, enqueueCloud: enqueueCloud)
                return true
            }
            if committed { return result }
        }
    }

    @MainActor public func saveChangesForInteraction(_ state: PlannerState, from baseline: PlannerState) async throws -> PlannerState {
        let container = container, backup = migrationBackupURL, outbox = cloudOutboxURL
        let merged = try await Task.detached(priority: .userInitiated) {
            let worker = LocalRepository(container: container, migrationBackupURL: backup, cloudOutboxURL: outbox)
            return try worker.saveChanges(state, from: baseline)
        }.value
        discardCachedModels()
        return merged
    }

    public func saveFixedEvent(_ edit: FixedEventEdit, now: Date = Date()) throws -> PlannerState {
        try update { latest, _ in
            try edit.apply(to: &latest, now: now)
            _ = latest.replan(now: now)
            return latest
        }
    }

    public func saveFixedOccurrence(_ edit: FixedEventOccurrenceEdit, now: Date = Date()) throws -> PlannerState {
        try update { latest, _ in
            let previous = latest
            try edit.apply(to: &latest, now: now)
            if latest != previous { _ = latest.replan(now: now) }
            return latest
        }
    }

    @MainActor public func saveFixedOccurrenceForInteraction(_ edit: FixedEventOccurrenceEdit,
                                                            from baseline: PlannerState, now: Date) async throws -> PlannerState {
        let container = container, backup = migrationBackupURL, outbox = cloudOutboxURL
        defer { discardCachedModels() }
        return try await Task.detached(priority: .userInitiated) {
            let worker = LocalRepository(container: container, migrationBackupURL: backup, cloudOutboxURL: outbox)
            return try worker.saveFixedOccurrence(edit, now: now)
        }.value
    }

    public func saveLessonOrder(_ draft: LessonOrderDraft, now: Date = Date()) throws -> PlannerState {
        try update { latest, _ in
            let previous = latest
            try draft.apply(to: &latest)
            if latest != previous { _ = latest.replan(now: now) }
            return latest
        }
    }

    @MainActor public func saveLessonOrderForInteraction(_ draft: LessonOrderDraft,
                                                        from baseline: PlannerState, now: Date) async throws -> PlannerState {
        let container = container, backup = migrationBackupURL, outbox = cloudOutboxURL
        defer { discardCachedModels() }
        return try await Task.detached(priority: .userInitiated) {
            let worker = LocalRepository(container: container, migrationBackupURL: backup, cloudOutboxURL: outbox)
            return try worker.saveLessonOrder(draft, now: now)
        }.value
    }

    @MainActor public func saveFixedEventForInteraction(_ edit: FixedEventEdit,
                                                       from baseline: PlannerState, now: Date) async throws -> PlannerState {
        let container = container, backup = migrationBackupURL, outbox = cloudOutboxURL
        let saved = try await Task.detached(priority: .userInitiated) {
            let worker = LocalRepository(container: container, migrationBackupURL: backup, cloudOutboxURL: outbox)
            return try worker.saveFixedEvent(edit, now: now)
        }.value
        discardCachedModels()
        return saved
    }

    /// Background sync writes through a separate context on the same store.
    /// Reuse the container instead of opening the database again on the UI thread.
    @MainActor public func discardCachedModels() {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func load() throws -> PlannerState {
        var state = PlannerState()
        let decoder = JSONDecoder()
        for row in try context.fetch(FetchDescriptor<LocalRecord>()) {
            switch row.kind {
            case "sync": break
            case "course": state.courses.append(try decoder.decode(Course.self, from: row.payload))
            case "fixed": state.fixedEvents.append(try decoder.decode(FixedEvent.self, from: row.payload))
            case "task": state.tasks.append(try decoder.decode(ScheduledTask.self, from: row.payload))
            case "completion": state.completions.append(try decoder.decode(CompletionRecord.self, from: row.payload))
            case "settings":
                let settings = try decoder.decode(SettingsPayload.self, from: row.payload)
                guard settings.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                state.settings = settings.settings; state.schemaVersion = settings.version
            default: throw CocoaError(.coderReadCorrupt)
            }
        }
        state.removeArchivedCourses()
        state.courses.sort { $0.startDate < $1.startDate }
        state.tasks.sort { $0.start < $1.start }
        return state
    }
    public func loadLedger() throws -> SyncLedger {
        for row in try context.fetch(FetchDescriptor<LocalRecord>()) where row.kind == "sync" {
            return try JSONDecoder().decode(SyncLedger.self, from: row.payload)
        }
        return SyncLedger()
    }
    public func save(_ state: PlannerState) throws {
        try backupBeforeMigrationIfNeeded()
        // The transactional overload captures the state once.
        try save(state, ledger: loadLedger())
    }
    private func backupBeforeMigrationIfNeeded() throws {
        if let backup = migrationBackupURL, !FileManager.default.fileExists(atPath: backup.path),
           !(try context.fetch(FetchDescriptor<LocalRecord>())).contains(where: { $0.kind == "sync" }) {
            try encoder.encode(load()).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
    }
    public func save(_ state: PlannerState, ledger: SyncLedger, enqueueCloud: Bool = true) throws {
        let previousSequence = try loadLedger().sequence
        var state = state
        state.removeArchivedCourses()
        var ledger = ledger
        try ledger.capture(state)
        var desired: [String: (String, Data)] = ["sync": ("sync", try encoder.encode(ledger))]
        for value in state.courses { desired["course/\(value.id)"] = ("course", try encoder.encode(value)) }
        for value in state.fixedEvents { desired["fixed/\(value.id)"] = ("fixed", try encoder.encode(value)) }
        for value in state.tasks { desired["task/\(value.id)"] = ("task", try encoder.encode(value)) }
        for value in state.completions { desired["completion/\(value.id)"] = ("completion", try encoder.encode(value)) }
        desired["settings"] = ("settings", try encoder.encode(SettingsPayload(version: state.schemaVersion, settings: state.settings)))
        do {
            for row in try context.fetch(FetchDescriptor<LocalRecord>()) {
                if let value = desired.removeValue(forKey: row.key) {
                    if row.payload != value.1 { row.payload = value.1 }
                } else { context.delete(row) }
            }
            for (key, value) in desired { context.insert(LocalRecord(key: key, kind: value.0, payload: value.1)) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        if enqueueCloud, ledger.sequence != previousSequence, let cloudOutboxURL,
           UserDefaults.standard.bool(forKey: CloudOutbox.enabledKey) {
            // A packaging failure must not undo a successful local save. Sync also rebuilds
            // a full pending snapshot from the durable ledger on the next attempt.
            do { try CloudOutbox.enqueue(ledger, directory: cloudOutboxURL) }
            catch { NotificationCenter.default.post(name: .plannerDidCommit, object: nil); return }
            NotificationCenter.default.post(name: .plannerDidCommit, object: nil)
        }
    }
}
