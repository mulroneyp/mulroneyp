import Foundation
import Security

/// Secure storage for the user's free eBird API key (Keychain).
/// Never logs or writes the key to UserDefaults, iCloud Birdlists, or the repo.
enum EBirdAPIKeyStore {
    private static let service = "com.mulroneyp.handyfieldguide.ebird-api"
    private static let account = "ebird-api-token"

    static var hasKey: Bool {
        !(load()?.isEmpty ?? true)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let sanitized = sanitize(key)
        return sanitized.isEmpty ? nil : sanitized
    }

    static func save(_ raw: String) throws {
        let sanitized = sanitize(raw)
        guard !sanitized.isEmpty else {
            throw KeyStoreError.empty
        }
        guard let data = sanitized.data(using: .utf8) else {
            throw KeyStoreError.encoding
        }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyStoreError.osStatus(status)
        }
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Trims whitespace/newlines and strips invisible / control characters that
    /// often hitch a ride when pasting from the keygen page.
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.unicodeScalars.filter { scalar in
            if scalar.value == 0xFEFF { return false } // BOM
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if scalar.properties.isDefaultIgnorableCodePoint { return false }
            return true
        })
    }

    enum KeyStoreError: LocalizedError {
        case empty
        case encoding
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter an eBird API key before saving."
            case .encoding:
                return "That API key could not be stored."
            case .osStatus(let status):
                return "Keychain error (\(status)). Try again."
            }
        }
    }
}
