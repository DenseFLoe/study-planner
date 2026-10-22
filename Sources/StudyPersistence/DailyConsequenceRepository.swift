import Foundation
import StudyCore

/// Local forecast history is deliberately separate from the synced business state.
public actor DailyConsequenceRepository {
    private let url: URL?
    private var memory = DailyConsequenceJournal()
    private var sequence = -1
    private var writeDisabled = false
    public init(inMemory: Bool = false, url: URL? = nil) {
        self.url = inMemory ? nil : (url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StudyPlanner/DailyConsequences.json"))
    }
    public func load() throws -> DailyConsequenceJournal {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return memory }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 8_000_000 else { throw CocoaError(.coderReadCorrupt) }
            let value = try JSONDecoder().decode(DailyConsequenceJournal.self, from: data)
            guard value.version == 1, value.days.count <= 31, Set(value.days.map(\.id)).count == value.days.count,
                  value.days.allSatisfy({ $0.goalMinutes >= 0 && $0.forecasts.count <= 5 }) else { throw CocoaError(.coderReadCorrupt) }
            memory = value
            return value
        } catch { writeDisabled = true; throw error }
    }
    public func save(_ value: DailyConsequenceJournal, sequence next: Int) throws {
        guard !writeDisabled else { throw CocoaError(.fileWriteNoPermission) }
        guard next > sequence else { return }
        var retained = value
        retained.days = Array(retained.days.sorted { $0.date < $1.date }.suffix(14))
        var data = try JSONEncoder().encode(retained)
        while data.count > 8_000_000 && retained.days.count > 1 {
            retained.days.removeFirst(); data = try JSONEncoder().encode(retained)
        }
        guard data.count <= 8_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        memory = retained; sequence = next
    }
}
