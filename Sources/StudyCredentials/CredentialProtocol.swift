import Foundation

// A fixed Objective-C name keeps the separately built service ABI independent of Swift modules.
@objc(StudyPlannerCredentialProtocol)
public protocol CredentialProtocol {
    func perform(_ request: Data, reply: @escaping (Data?, Int32) -> Void)
}

public struct CredentialRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case ping, load, save, delete }
    public var operation: Operation
    public var service: String
    public var account: String
    public var value: Data?
    public var interactive: Bool

    public init(_ operation: Operation, service: String, account: String, value: Data? = nil, interactive: Bool = true) {
        self.operation = operation; self.service = service; self.account = account
        self.value = value; self.interactive = interactive
    }

    public var isValid: Bool {
        if operation == .ping { return service.isEmpty && account.isEmpty && value == nil }
        guard value?.count ?? 0 <= 65_536, (operation == .save) == (value != nil) else { return false }
        switch service {
        case "local.studyplanner.cloud": return ["server", "ssh-server"].contains(account)
        case "local.studyplanner.sync": return account == "android"
        case "local.studyplanner.website-account": return ["yantu", "xuecheng"].contains(account)
        case "local.studyplanner.assistant.sdk-v2":
            return account.utf8.count == 64 && account.allSatisfy { "0123456789abcdef".contains($0) }
        case "local.studyplanner.credential-probe":
            // An isolated, disposable fixture used by package acceptance. Never accepts real secrets.
            return UUID(uuidString: account) != nil && (value == nil || value == Self.fixture)
        default: return false
        }
    }

    public static let fixture = Data("synthetic-fixture-not-a-real-credential".utf8)
}
