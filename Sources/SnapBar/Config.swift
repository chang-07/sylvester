import Foundation

struct SnapBarConfig: Codable {
    var clientId: String
    var consumerKey: String
    var userId: String
    var userSecret: String
    var baseCurrency: String
    var refreshMinutes: Int
    // Manual FX overrides (units of baseCurrency per 1 unit of key), e.g. {"CAD": 0.73}.
    // Used as fallback when the live FX fetch fails.
    var fxRates: [String: Double]?

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/snapbar", isDirectory: true)
    static let path = dir.appendingPathComponent("config.json")

    static let template = SnapBarConfig(
        clientId: "",
        consumerKey: "",
        userId: "",
        userSecret: "",
        baseCurrency: "USD",
        refreshMinutes: 15,
        fxRates: nil
    )

    var hasPartnerCreds: Bool { !clientId.isEmpty && !consumerKey.isEmpty }
    var hasUser: Bool { !userId.isEmpty && !userSecret.isEmpty }

    static func load() -> SnapBarConfig? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        guard var cfg = try? JSONDecoder().decode(SnapBarConfig.self, from: data) else { return nil }
        // Stray whitespace in pasted keys breaks signing with an opaque 401.
        cfg.clientId = cfg.clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.consumerKey = cfg.consumerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.userId = cfg.userId.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.userSecret = cfg.userSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keychain-mode: secrets live in the keychain, file fields are blank.
        if cfg.consumerKey.isEmpty, let key = KeychainStore.get("consumerKey") {
            cfg.consumerKey = key
        }
        if cfg.userSecret.isEmpty, let secret = KeychainStore.get("userSecret") {
            cfg.userSecret = secret
        }
        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        var toWrite = self
        // Once the keychain holds the consumer key, never write secrets back to disk.
        if KeychainStore.get("consumerKey") != nil {
            if !consumerKey.isEmpty { KeychainStore.set("consumerKey", consumerKey) }
            if !userSecret.isEmpty { KeychainStore.set("userSecret", userSecret) }
            toWrite.consumerKey = ""
            toWrite.userSecret = ""
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(toWrite).write(to: Self.path, options: .atomic)
        // Keys may live in this file (non-keychain mode) — keep it owner-readable only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path.path)
    }

    // Switch to keychain mode: move secrets out of the file.
    func moveSecretsToKeychain() throws {
        KeychainStore.set("consumerKey", consumerKey)
        if !userSecret.isEmpty { KeychainStore.set("userSecret", userSecret) }
        try save()
    }

    // Writes a template config if none exists; returns whether one already existed.
    @discardableResult
    static func ensureExists() -> Bool {
        if FileManager.default.fileExists(atPath: path.path) { return true }
        try? template.save()
        return false
    }
}
