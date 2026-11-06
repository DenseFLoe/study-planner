import Foundation
import Observation
import Security
import CryptoKit
import StudyCore

enum AssistantVault {
    private static func query(_ configuration: AssistantConfiguration) throws -> [String: Any] {
        let url = try configuration.validatedURL()
        let account = SHA256.hash(data: Data((configuration.provider.rawValue + "|" + url.absoluteString).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "local.studyplanner.assistant",
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false]
    }
    static func load(_ configuration: AssistantConfiguration) throws -> String {
        var query = try query(configuration)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { throw AssistantError.key }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AssistantError.keychain }
        return key
    }
    static func save(_ key: String, configuration: AssistantConfiguration) throws {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace }) else { throw AssistantError.key }
        let query = try query(configuration), data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard status == errSecItemNotFound, SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AssistantError.keychain }
    }
    static func delete(_ configuration: AssistantConfiguration) throws {
        let status = SecItemDelete(try query(configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.keychain }
    }
}

struct AssistantPreview: Equatable, Sendable {
    var configuration: AssistantConfiguration
    var question: String
    var evidence: AssistantEvidence
    // Only used locally to invalidate confirmation after sync/edit; never serialized.
    var source: PlannerState
}

@MainActor @Observable
final class AssistantSession {
    var configuration: AssistantConfiguration
    var key = ""
    var question = "为什么这样安排？请引用数据说明。"
    private(set) var preview: AssistantPreview?
    private(set) var answer = ""
    private(set) var answeredPreview: AssistantPreview?
    private(set) var busy = false
    private(set) var preparing = false
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let transport: any AssistantTransport
    @ObservationIgnored private let defaults: UserDefaults?
    static let defaultsKey = "studyAssistant.configuration.v1"

    init(transport: any AssistantTransport = AssistantHTTPTransport(), defaults: UserDefaults? = .standard) {
        self.transport = transport; self.defaults = defaults
        configuration = defaults?.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AssistantConfiguration.self, from: $0) } ?? .init()
    }
    func switchProvider(_ provider: AssistantProvider) {
        invalidate()
        key = ""; configuration = .init(provider: provider, endpoint: provider.endpoint, model: "")
    }
    func invalidate(clearAnswer: Bool = true) {
        let wasBusy = busy
        generation = UUID(); task?.cancel(); task = nil
        preview = nil; busy = false; preparing = false
        if clearAnswer { answer = ""; answeredPreview = nil }
        message = wasBusy ? AssistantError.cancelled.localizedDescription : nil
    }
    func close() { invalidate(); key = ""; question = "" }

    func prepare(state: PlannerState, day: Date, courseID: UUID?, includeNames: Bool,
                 result: ScheduleResult? = nil, dailyWarningMinutes: Int = 480) async {
        guard !busy, !preparing else { return }
        invalidate()
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 6000 else { message = "请输入问题，最多6000字节（约2000个汉字）。"; return }
        let token = generation, config = configuration
        preparing = true
        let evidence = await Task.detached(priority: .userInitiated) {
            AssistantEvidence.build(state: state, day: day, courseID: courseID, includeNames: includeNames,
                                    result: result, dailyWarningMinutes: dailyWarningMinutes)
        }.value
        guard token == generation, !Task.isCancelled else { return }
        preparing = false
        preview = .init(configuration: config, question: value, evidence: evidence, source: state)
    }

    func send(currentState: PlannerState) {
        guard !busy, !preparing, let approved = preview else { return }
        guard approved.source == currentState, approved.configuration == configuration,
              approved.question == question.trimmingCharacters(in: .whitespacesAndNewlines) else {
            invalidate(); message = "数据或配置已变化，请重新预览后发送。"; return
        }
        do {
            let request = try AssistantWire.request(configuration: approved.configuration, key: key,
                                                    question: approved.question, evidence: approved.evidence.text)
            if let data = try? JSONEncoder().encode(configuration) { defaults?.set(data, forKey: Self.defaultsKey) }
            busy = true; message = nil; answer = ""; answeredPreview = nil
            // Consumed exactly once: another click or a failure cannot replay this approval.
            preview = nil
            let token = generation, transport = transport
            task = Task { [weak self] in
                do {
                    let answer = try await transport.send(request, provider: approved.configuration.provider)
                    guard let self, token == self.generation, !Task.isCancelled else { return }
                    self.answer = answer; self.answeredPreview = approved; self.busy = false; self.task = nil
                    self.message = approved.evidence.citationWarning(in: answer)
                } catch {
                    guard let self, token == self.generation else { return }
                    self.message = AssistantError.safe(error).localizedDescription; self.busy = false; self.task = nil
                }
            }
        } catch { message = AssistantError.safe(error).localizedDescription }
    }

    func waitForRequest() async { await task?.value }
}
