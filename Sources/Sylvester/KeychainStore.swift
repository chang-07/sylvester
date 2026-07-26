import Foundation
import Security

// Generic-password storage in the login keychain. Presence of the "consumerKey"
// secret switches the app into keychain mode: config.json then holds no secrets.
//
// Everything lives in ONE keychain item as a JSON blob rather than one item per secret.
// Each item carries its own ACL bound to the creating binary's code signature, and an
// ad-hoc signature changes identity on every rebuild — so the old four-item layout meant
// up to four separate "Sylvester wants to use your confidential information" prompts after
// every update. One item is one prompt. (Stable Developer ID signing is what removes it
// entirely; this just stops it being a pile-up.) Legacy items migrate in on first read.
enum KeychainStore {
    private static let service = "com.chang.sylvester"
    private static let blobAccount = "secrets"
    private static let legacyAccounts = ["consumerKey", "userSecret", "accessToken", "refreshToken"]
    // Pre-rebrand service name. The Keychain service IS the bundle id, so renaming the app
    // orphaned every secret it had stored.
    private static let snapBarService = "com.chang.snapbar"

    // Read-through cache. Config.load() asks for four secrets in a row; without this that
    // is four keychain round-trips (and, pre-consolidation, four prompts) per launch.
    private static var cache: [String: String]?

    static func get(_ key: String) -> String? {
        let value = all()[key]
        return (value?.isEmpty ?? true) ? nil : value
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        var secrets = all()
        secrets[key] = value
        return write(secrets)
    }

    static func delete(_ key: String) {
        var secrets = all()
        guard secrets.removeValue(forKey: key) != nil else { return }
        write(secrets)
    }

    private static func all() -> [String: String] {
        if let cache { return cache }
        var secrets = readBlob() ?? [:]
        if secrets.isEmpty, let migrated = migrateLegacy() { secrets = migrated }
        cache = secrets
        return secrets
    }

    private static func readBlob() -> [String: String]? {
        guard let data = rawRead(blobAccount) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    // One-time move from the old item-per-secret layout. Costs one last round of prompts,
    // then never again. Legacy items are removed only once the consolidated blob is
    // safely written — a failed write must not lose the user's tokens.
    private static func migrateLegacy() -> [String: String]? {
        var found: [String: String] = [:]
        for account in legacyAccounts {
            if let data = rawRead(account),
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                found[account] = value
            }
        }
        guard !found.isEmpty else { return nil }
        guard write(found, updatingCache: false) else { return found }
        for account in legacyAccounts { rawDelete(account) }
        return found
    }

    @discardableResult
    private static func write(_ secrets: [String: String], updatingCache: Bool = true) -> Bool {
        guard let data = try? JSONEncoder().encode(secrets) else { return false }
        if updatingCache { cache = secrets }
        return rawWrite(blobAccount, data)
    }

    // Carry the secrets across the rebrand. Handles both post-consolidation (one blob) and
    // the older item-per-secret layout, in case this install skipped that build.
    //
    // This is the one migration step that surfaces a Keychain prompt, and it's unavoidable:
    // the old item's ACL was written for an app the renamed binary simply isn't.
    static func migrateFromSnapBar() {
        guard readBlob() == nil else { return }
        var secrets: [String: String] = [:]
        if let data = rawRead(blobAccount, service: snapBarService),
           let blob = try? JSONDecoder().decode([String: String].self, from: data) {
            secrets = blob
        } else {
            for account in legacyAccounts {
                if let data = rawRead(account, service: snapBarService),
                   let value = String(data: data, encoding: .utf8), !value.isEmpty {
                    secrets[account] = value
                }
            }
        }
        guard !secrets.isEmpty else { return }
        write(secrets)
    }

    // MARK: - Raw item access

    private static func query(_ account: String, service: String = KeychainStore.service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func rawRead(_ account: String, service: String = KeychainStore.service) -> Data? {
        var q = query(account, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func rawWrite(_ account: String, _ data: Data) -> Bool {
        let base = query(account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            // Available whenever the keychain is unlocked, which for a login-item menubar
            // app is exactly the window in which it runs.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func rawDelete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
