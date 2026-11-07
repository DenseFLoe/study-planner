import Foundation
import Security

public enum CredentialClient {
    public static let serviceName = "local.studyplanner.credentials"

    /// No fallback after an XPC failure: that would restore prompts under the changing app identity.
    public static func perform(_ request: CredentialRequest) -> (Data?, OSStatus) {
        guard request.isValid else { return (nil, errSecParam) }
        guard let requirement = Bundle.main.object(forInfoDictionaryKey: "StudyPlannerCredentialServiceRequirement") as? String else {
            // SwiftPM/CI and older ad-hoc packages retain their previous direct-keychain behavior.
            guard Bundle.main.object(forInfoDictionaryKey: "StudyPlannerSigningMode") as? String != "local-vault" else {
                return (nil, errSecAuthFailed)
            }
            return CredentialStore.perform(request)
        }
        guard !requirement.isEmpty else { return (nil, errSecAuthFailed) }
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: CredentialProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }
        // Authenticate a reply before transmitting any credential to the service.
        let handshake = exchange(.init(.ping, service: "", account: "", interactive: false), connection: connection, timeout: 10)
        guard handshake.1 == errSecSuccess else { return handshake }
        // Don't report a write as failed while a user is still deciding in the system dialog.
        // Service interruption is delivered through the proxy's error handler.
        return exchange(request, connection: connection, timeout: request.interactive ? nil : 15)
    }

    private static func exchange(_ request: CredentialRequest, connection: NSXPCConnection, timeout: TimeInterval?) -> (Data?, OSStatus) {
        guard let data = try? JSONEncoder().encode(request) else { return (nil, errSecParam) }
        let response = Response()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            response.finish(nil, errSecAuthFailed)
        }) as? CredentialProtocol else {
            return (nil, errSecAuthFailed)
        }
        proxy.perform(data) { value, status in response.finish(value, status) }
        guard response.signal.wait(timeout: timeout.map { .now() + $0 } ?? .distantFuture) == .success else { return (nil, errSecInteractionNotAllowed) }
        return response.result
    }

    private final class Response: @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: (Data?, OSStatus)?
        var result: (Data?, OSStatus) { lock.lock(); defer { lock.unlock() }; return value ?? (nil, errSecInternalError) }
        func finish(_ data: Data?, _ status: OSStatus) {
            lock.lock(); defer { lock.unlock() }
            guard value == nil else { return }
            value = (data, status); signal.signal()
        }
    }
}
