import Foundation
import Security

final class Service: NSObject, CredentialProtocol {
    private let queue = DispatchQueue(label: "local.studyplanner.credentials.operations")
    func perform(_ data: Data, reply: @escaping (Data?, Int32) -> Void) {
        guard data.count <= 100_000, let request = try? JSONDecoder().decode(CredentialRequest.self, from: data), request.isValid else {
            reply(nil, errSecParam); return
        }
        queue.async {
            let result = CredentialStore.perform(request)
            reply(result.0, result.1)
        }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              let requirement = Bundle.main.object(forInfoDictionaryKey: "StudyPlannerAllowedClient") as? String,
              !requirement.isEmpty else { return false }
        // XPC validates every incoming message's actual sender; no PID/path-only trust checks.
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: CredentialProtocol.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
