import Foundation
import Security

/// Minimal Keychain wrapper for storing string credentials.
///
/// Why this exists: SpeechCraft v1.01 stored API keys in plain UserDefaults
/// (`~/Library/Preferences/com.esawtooth.SpeechCraft.plist`), which is readable
/// by any process running as the user. Keychain requires explicit permission
/// from the system to access, and the values are encrypted at rest.
///
/// Service identifier intentionally distinct from `claude-creds` (used by
/// `~/.claude/bin/secrets`) so SpeechCraft owns its own keychain entries.
enum KeychainStore {
    private static let service = "com.haredigital.speechcraft"

    /// Store a credential. Overwrites any existing value with the same key.
    static func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Delete any existing entry first to avoid duplicate-item errors
        delete(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // Only this app can read; require device unlock
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("KeychainStore.set failed for key '\(key)': OSStatus \(status)")
        }
    }

    /// Retrieve a credential. Returns nil if not found.
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    /// Delete a credential. Silently succeeds if the key doesn't exist.
    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration: move credentials from UserDefaults to Keychain.
    ///
    /// Call once at app launch. If the key exists in UserDefaults but not in
    /// Keychain, copy it across and remove the UserDefaults version. This
    /// migrates upstream SpeechCraft users without forcing them to re-enter
    /// their API key.
    static func migrateFromUserDefaults(keys: [String]) {
        let defaults = UserDefaults.standard
        for key in keys {
            // Skip if already in Keychain
            if get(key) != nil { continue }

            // Migrate if present in UserDefaults
            if let legacyValue = defaults.string(forKey: key), !legacyValue.isEmpty {
                set(legacyValue, forKey: key)
                defaults.removeObject(forKey: key)
                NSLog("KeychainStore: migrated '\(key)' from UserDefaults to Keychain")
            }
        }
    }
}
