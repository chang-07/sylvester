import Foundation

// One-shot carry-over from the SnapBar era.
//
// The rebrand changed the bundle identifier, and on macOS that identifier is the key to
// three separate stores: the Keychain service, the UserDefaults domain, and — by this
// app's own convention — the config directory. None of them follow the app across a
// rename. Without this, upgrading would look exactly like a factory reset: signed out,
// preferences gone, net-worth history gone.
//
// Everything here copies rather than moves. An older SnapBar build left installed should
// keep working rather than find its data spirited away mid-migration.
enum LegacyMigration {
    private static let marker = "sylvester.migratedFromSnapBar"
    private static let snapBarBundleId = "com.chang.snapbar"
    private static let snapBarDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/snapbar", isDirectory: true)

    // Must run before AppState is constructed — its init reads config and Keychain
    // immediately, and would cache the empty results.
    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        migrateConfigDirectory()
        migrateDefaults()
        KeychainStore.migrateFromSnapBar()
        UserDefaults.standard.set(true, forKey: marker)
    }

    private static func migrateConfigDirectory() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapBarDir.path) else { return }
        // Never overwrite a config the user already has under the new name.
        guard !fm.fileExists(atPath: SylvesterConfig.path.path) else { return }

        try? fm.createDirectory(at: SylvesterConfig.dir, withIntermediateDirectories: true)
        for name in ["config.json", "history.json", "seen_activities.json"] {
            let source = snapBarDir.appendingPathComponent(name)
            let destination = SylvesterConfig.dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path),
                  !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.copyItem(at: source, to: destination)
        }
        // config.json may hold partner keys on installs that never moved to the Keychain.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: SylvesterConfig.path.path)
    }

    // Preferences live in a per-bundle-id plist, so the old domain is still readable —
    // just under a name nothing looks at any more. Re-key "snapbar.*" to "sylvester.*".
    private static func migrateDefaults() {
        guard let legacy = UserDefaults(suiteName: snapBarBundleId) else { return }
        let store = UserDefaults.standard
        let prefix = "snapbar."
        for (key, value) in legacy.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let renamed = "sylvester." + key.dropFirst(prefix.count)
            // Don't clobber a preference already set under the new name.
            guard store.object(forKey: renamed) == nil else { continue }
            store.set(value, forKey: renamed)
        }
    }
}
