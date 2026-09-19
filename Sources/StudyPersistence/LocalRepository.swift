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
}

public final class LocalRepository: PlannerRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let encoder: JSONEncoder
    private let migrationBackupURL: URL?
    private struct SettingsPayload: Codable {
        var version: Int
        var settings: AppSettings
    }
    public init(inMemory: Bool = false, url: URL? = nil) throws {
        let configuration: ModelConfiguration
        if let url {
            migrationBackupURL = nil
            configuration = ModelConfiguration("StudyPlanner", url: url, cloudKitDatabase: .none)
        } else if inMemory {
            migrationBackupURL = nil
            configuration = ModelConfiguration("StudyPlanner", isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("StudyPlanner", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            migrationBackupURL = directory.appendingPathComponent("before-local-sync.json")
            configuration = ModelConfiguration("StudyPlanner", url: directory.appendingPathComponent("StudyPlanner.store"), cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: LocalRecord.self, configurations: configuration)
        context = ModelContext(container)
        context.autosaveEnabled = false
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
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
        if let backup = migrationBackupURL, !FileManager.default.fileExists(atPath: backup.path),
           !(try context.fetch(FetchDescriptor<LocalRecord>())).contains(where: { $0.kind == "sync" }) {
            try encoder.encode(load()).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        var ledger = try loadLedger()
        try ledger.capture(state)
        try save(state, ledger: ledger)
    }
    public func save(_ state: PlannerState, ledger: SyncLedger) throws {
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
    }
}
