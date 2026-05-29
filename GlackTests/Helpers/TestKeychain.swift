import Foundation
import Security

/// Test-scoped Keychain helpers. The real KeychainStore writes to service
/// `com.github.taha-abbasi.glack`; tests must use a different service so
/// they can be cleaned up independently and never collide with the user's
/// real session.
enum TestKeychain {
    static let testService = "com.github.taha-abbasi.glack.tests"

    static func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let delete: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(delete as CFDictionary)

        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Cleanup gate: refuses to delete anything outside the test service.
    /// Mirrors AskFlorence's "only delete things matching SYNTHETIC_PATTERN"
    /// pattern so a misconfigured test can never wipe the real Keychain entry.
    static func deleteAll() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
        ]
        _ = SecItemDelete(q as CFDictionary)
    }
}
