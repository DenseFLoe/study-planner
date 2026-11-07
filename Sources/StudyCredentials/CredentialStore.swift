import Foundation
import Security

/// Used only by the standalone service, or by an explicitly legacy/development build.
/// Serialize the process-wide interaction flag so background queries never open a password dialog.
public enum CredentialStore {
    private static let lock = NSLock()
    public static func perform(_ request: CredentialRequest) -> (Data?, OSStatus) {
        guard request.isValid else { return (nil, errSecParam) }
        if request.operation == .ping { return (nil, errSecSuccess) }
        lock.lock(); defer { lock.unlock() }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(request.interactive) == errSecSuccess else {
            return (nil, errSecInteractionNotAllowed)
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: request.service, kSecAttrAccount as String: request.account,
            kSecAttrSynchronizable as String: false]
        switch request.operation {
        case .load:
            var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(item as CFDictionary, &result)
            return (result as? Data, status)
        case .save:
            guard let value = request.value else { return (nil, errSecParam) }
            // The legacy Keychain can allow an update even when it denies a read. Require
            // access to the existing item first so a cancelled migration cannot overwrite it.
            var existing = query; existing[kSecReturnData as String] = true
            existing[kSecMatchLimit as String] = kSecMatchLimitOne
            var previousValue: CFTypeRef?
            let status = SecItemCopyMatching(existing as CFDictionary, &previousValue)
            if status == errSecSuccess {
                return (nil, SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary))
            }
            // A denied/cancelled read never deletes or recreates an existing credential.
            guard status == errSecItemNotFound else { return (nil, status) }
            var item = query; item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = request.service == "local.studyplanner.assistant.sdk-v2"
                ? kSecAttrAccessibleWhenUnlockedThisDeviceOnly : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return (nil, SecItemAdd(item as CFDictionary, nil))
        case .delete: return (nil, SecItemDelete(query as CFDictionary))
        case .ping: return (nil, errSecSuccess)
        }
    }
}
