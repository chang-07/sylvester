import Foundation

// Partner keys use the HMAC/registerUser model; personal keys use the DOT OAuth2
// bearer flow (browser sign-in → access/refresh tokens), which registerUser rejects.
enum AuthMode: String, Codable {
    case partner
    case personal
}

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

    // Personal-key OAuth state. Absent on classic partner-key configs (nil => partner).
    var authMode: String? = nil          // "partner" (default) | "personal"
    var oauthClientId: String? = nil     // DCR-registered public client id (non-secret)
    var accessToken: String? = nil       // bearer token — Keychain only, never on disk
    var refreshToken: String? = nil      // rotates each refresh — Keychain only
    var accessTokenExpiry: Double? = nil // epoch seconds; refresh before this

    // API host override (default prod). Drives both the data plane and OAuth discovery, so
    // one value repoints everything, e.g. apiBaseURL="https://api.staging.snaptrade.com".
    var apiBaseURL: String? = nil        // default https://api.snaptrade.com

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

    var mode: AuthMode { AuthMode(rawValue: authMode ?? "") ?? .partner }
    // Personal OAuth is "signed in" once we hold a refresh token (access tokens are
    // short-lived and re-minted from it); the access token alone suffices right after login.
    var hasOAuthSession: Bool { !(refreshToken ?? "").isEmpty || !(accessToken ?? "").isEmpty }

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
        // OAuth tokens live only in the Keychain.
        if (cfg.accessToken ?? "").isEmpty { cfg.accessToken = KeychainStore.get("accessToken") }
        if (cfg.refreshToken ?? "").isEmpty { cfg.refreshToken = KeychainStore.get("refreshToken") }
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
        // OAuth tokens are always Keychain-only, never written to disk.
        if let at = accessToken, !at.isEmpty { KeychainStore.set("accessToken", at) }
        if let rt = refreshToken, !rt.isEmpty { KeychainStore.set("refreshToken", rt) }
        toWrite.accessToken = nil
        toWrite.refreshToken = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(toWrite).write(to: Self.path, options: .atomic)
        // Keys may live in this file (non-keychain mode) — keep it owner-readable only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path.path)
    }

    // Sign out of personal OAuth: drop tokens from Keychain + memory. Keeps the
    // registered oauthClientId so we don't re-run DCR on the next sign-in.
    mutating func clearOAuthSession() {
        KeychainStore.delete("accessToken")
        KeychainStore.delete("refreshToken")
        accessToken = nil
        refreshToken = nil
        accessTokenExpiry = nil
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
