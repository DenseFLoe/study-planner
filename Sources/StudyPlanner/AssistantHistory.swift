import Foundation

struct AssistantConversation: Codable, Identifiable, Sendable {
    var id: UUID
    var updatedAt: Date
    var entries: [AssistantChatEntry]
    var title: String { String((entries.first { $0.role == "你" }?.text ?? "新对话").prefix(32)) }
}

/// Separate from the planner database, sync, backups and credentials.
struct AssistantHistoryStore {
    let url: URL
    static var local: Self {
        .init(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyPlannerAssistant/conversations-v1.json"))
    }
    static let limit = 8_000_000
    func load() throws -> [AssistantConversation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= Self.limit else { throw AssistantError.history }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.limit else { throw AssistantError.history }
        let conversations = try JSONDecoder().decode([AssistantConversation].self, from: data)
        guard conversations.count <= 100, Set(conversations.map(\.id)).count == conversations.count,
              conversations.allSatisfy({ Set($0.entries.map(\.id)).count == $0.entries.count }) else { throw AssistantError.history }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }
    func save(_ conversations: [AssistantConversation]) throws {
        let data = try JSONEncoder().encode(conversations)
        guard conversations.count <= 100, data.count <= Self.limit else { throw AssistantError.history }
        let manager = FileManager.default, folder = url.deletingLastPathComponent()
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw AssistantError.history }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
