import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UserNotifications

// A connection queued for removal, pending the inline confirm.
struct RemovalTarget: Identifiable {
    let id: String
    let name: String
}

// Shared vocabulary for the permissions checklist. macOS grants these through three
// different APIs with three different vocabularies; the UI only cares about four states.
enum PermissionStatus {
    case notRequested
    case granted
    case denied
    // Registered, but macOS wants the user to confirm in System Settings before it counts.
    case needsApproval

    init(notification: UNAuthorizationStatus) {
        switch notification {
        case .authorized, .provisional, .ephemeral: self = .granted
        case .denied: self = .denied
        default: self = .notRequested
        }
    }

    init(loginItem: SMAppService.Status) {
        switch loginItem {
        case .enabled: self = .granted
        case .requiresApproval: self = .needsApproval
        // .notFound (bundle not known to Launch Services, e.g. running from a build dir)
        // stays "not requested" rather than "denied": the Enable button should remain
        // live, and if registration really can't work the throw surfaces the reason.
        default: self = .notRequested
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .needsApproval: return "exclamationmark.circle.fill"
        case .notRequested: return "circle.dashed"
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .denied: return Theme.alert
        case .needsApproval: return .orange
        case .notRequested: return .secondary
        }
    }

    var actionTitle: String {
        switch self {
        case .granted: return "Enabled"
        case .denied: return "Open Settings"
        case .needsApproval: return "Approve"
        case .notRequested: return "Enable"
        }
    }
}

struct InstitutionGroup: Identifiable {
    var id: String { name }
    var name: String
    var accounts: [STAccount]
    var totalInBase: Double
}

struct AccountDetail {
    var positions: [STPosition] = []
    var cashByCurrency: [(code: String, amount: Double)] = []
    var activities: [STActivity] = []
    // Live-fetched balance from GET /accounts/{id}; the listAccounts balance only
    // advances on SnapTrade's daily background sync.
    var liveBalance: STAccount.Balance?
    var error: String?
}

@MainActor
final class AppState: ObservableObject {
    enum Phase {
        case needsConfig(String)   // message explaining what's missing
        case ready
    }

    @Published var phase: Phase = .needsConfig("Loading…")
    @Published var config: SylvesterConfig = .template
    @Published var groups: [InstitutionGroup] = []
    @Published var details: [String: AccountDetail] = [:]
    // Connections with no synced accounts yet (first sync pending, or broken/disabled).
    @Published var attentionConnections: [STAuthorization] = []
    @Published var netWorth: Double = 0
    @Published var history: [HistoryPoint] = HistoryStore.load()
    @Published var fx: FXConverter?
    @Published var activities: [STActivity] = []
    @Published var unseenActivityCount = 0
    @Published var quotes: [String: Quote] = [:]
    @Published var privacyMode = UserDefaults.standard.bool(forKey: "sylvester.privacy") {
        didSet { UserDefaults.standard.set(privacyMode, forKey: "sylvester.privacy") }
    }
    // Popover UI state lives here, NOT as @State in MenuView, for the same reason the
    // wizard drafts do: the MenuBarExtra window tears down its view (and all its @State)
    // whenever it loses focus, so an expanded row — or a pending remove confirm — would
    // silently reset every time you switched to another app and came back.
    @Published var expandedAccounts: Set<String> = []
    @Published var removalTarget: RemovalTarget?
    private var seenActivities = SeenActivitiesStore.load()
    private var activitiesLastViewed: TimeInterval {
        get { UserDefaults.standard.double(forKey: "sylvester.activities.lastViewed") }
        set { UserDefaults.standard.set(newValue, forKey: "sylvester.activities.lastViewed") }
    }

    private var pendingPollTask: Task<Void, Never>?
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var fxNote: String?

    private var refreshLoop: Task<Void, Never>?
    // nil until the first successful refresh baselines it — pre-existing breakage
    // shouldn't fire a notification on every app launch.
    private var knownDisabledAuthIds: Set<String>?

    var client: SnapTradeClient {
        // Personal keys authenticate with the OAuth bearer token; partner keys with HMAC.
        var c: SnapTradeClient
        if config.mode == .personal, let token = config.accessToken, !token.isEmpty {
            c = SnapTradeClient(bearerToken: token)
        } else {
            c = SnapTradeClient(clientId: config.clientId, consumerKey: config.consumerKey)
        }
        if let api = config.apiBaseURL, let url = URL(string: api) { c.baseURL = url }
        return c
    }

    // OAuthClient with any host overrides from config applied (defaults to prod).
    private func makeOAuthClient() -> OAuthClient {
        var oauth = OAuthClient()
        // apiBase drives discovery, which in turn yields the authorize/token/register URLs.
        if let api = config.apiBaseURL, let url = URL(string: api) { oauth.apiBase = url }
        return oauth
    }

    init() {
        reloadConfig()
        // Lets the "Reconnect" button on a broken-connection banner open the portal
        // directly, without routing the user back through the popover.
        Notifier.shared.onReconnect = { [weak self] authId in
            Task { @MainActor in await self?.reconnectAuthorization(id: authId) }
        }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = self?.config.refreshMinutes ?? 15
                try? await Task.sleep(for: .seconds(max(5, minutes) * 60))
                await self?.refresh()
            }
        }
        // The menubar image bakes appearance-specific colors; rebuild it on theme flips.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateMenuImage()
                self?.objectWillChange.send()
            }
        }
    }

    // Menubar label pieces: adaptive text on both sides of a color-baked percent image.
    var menuValue: String {
        guard case .ready = phase else { return "Sylvester" }
        return moneyCompact(netWorth, config.baseCurrency)
    }

    var menuChange: (text: String, up: Bool)? {
        guard case .ready = phase,
              let change = marketDayChange ?? sessionDelta,
              abs(change.pct) >= 0.005
        else { return nil }
        let up = change.delta >= 0
        return (String(format: "%@%.2f%%", up ? "▲" : "▼", abs(change.pct)), up)
    }

    var menuSuffix: String {
        guard case .ready = phase else { return "" }
        var suffix = ""
        // Latest activity — tickers reveal holdings, so skip it in privacy mode.
        if !privacyMode, let latest = latestActivityCompact {
            suffix = "· \(latest)"
        }
        if unseenActivityCount > 0 {
            suffix += " •\(min(unseenActivityCount, 9))\(unseenActivityCount > 9 ? "+" : "")"
        }
        if errorMessage != nil { suffix += " ⚠︎" }
        return suffix.trimmingCharacters(in: .whitespaces)
    }

    // Most recent activity, e.g. "Buy XEQT" / "Div XEQT" / "Withdrew".
    //
    // Two vocabularies on purpose. With a ticker trailing it, a clipped verb still parses
    // — "Div XEQT" is unambiguous. Alone it doesn't: "Wd" and "Xfr" were unreadable in the
    // menubar precisely because there was no ticker to give them context. Those spell out,
    // and they can afford to — no ticker means the space is already free.
    var latestActivityCompact: String? {
        guard let activity = activities.first else { return nil }
        let type = (activity.type ?? "").uppercased()
        // Drop the exchange suffix for menubar brevity (XEQT.TO -> XEQT).
        let ticker = activity.ticker.map { raw -> String in
            String((raw.split(separator: ".").first.map(String.init) ?? raw).prefix(6))
        }

        let clipped: String
        let spelled: String
        switch type {
        case "BUY": clipped = "Buy"; spelled = "Bought"
        case "SELL": clipped = "Sell"; spelled = "Sold"
        case "DIVIDEND": clipped = "Div"; spelled = "Dividend"
        case "REI", "DIVIDEND_REINVESTMENT": clipped = "DRIP"; spelled = "Reinvested"
        case "INTEREST": clipped = "Int"; spelled = "Interest"
        case "CONTRIBUTION": clipped = "Dep"; spelled = "Deposit"
        case "WITHDRAWAL": clipped = "Wd"; spelled = "Withdrew"
        case "FEE", "TAX": clipped = "Fee"; spelled = "Fee"
        case "TRANSFER": clipped = "Xfr"; spelled = "Transfer"
        default:
            spelled = type.isEmpty
                ? "Activity"
                : type.replacingOccurrences(of: "_", with: " ").capitalized
            clipped = spelled
        }
        return ticker.map { "\(clipped) \($0)" } ?? spelled
    }

    private var menuImageCache: (key: String, image: NSImage)?

    func invalidateMenuImage() {
        menuImageCache = nil
    }

    // The whole menubar label as ONE image: MenuBarExtra treats a separate Image as a
    // Label icon (hoisted to the front, texts mangled), and template rendering strips
    // text color — so compose value + colored percent + activity ourselves, with
    // foregrounds resolved for the current menubar appearance.
    func menuBarImage() -> NSImage? {
        guard case .ready = phase else { return nil }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let change = menuChange
        let suffix = menuSuffix
        // Scale is part of the key: dragging to a display with a different backing factor
        // has to re-render, or the cached bitmap shows up soft.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(menuValue)|\(change?.text ?? "")|\(change?.up ?? false)|\(suffix)|\(isDark)|\(scale)"
        if let menuImageCache, menuImageCache.key == key { return menuImageCache.image }

        let fg: Color = isDark ? .white.opacity(0.92) : .black.opacity(0.88)

        // monospacedDigit is load-bearing, not cosmetic: proportional digits change width as
        // the value ticks, and because the menubar lays out right-to-left every item to our
        // left slides a pixel or two on every refresh. Fixed-width digits pin it.
        var label = Text(menuValue)
            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(fg)
        if let change {
            label = label + Text(" \(change.text)")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(change.up ? Theme.bakedGain(dark: isDark) : Theme.bakedLoss(dark: isDark))
        }
        if !suffix.isEmpty {
            // One space — the suffix already leads with a middot, so a second space just
            // opened a gap wide enough to read as a separate menubar item.
            label = label + Text(" \(suffix)")
                .font(.system(size: 12))
                .foregroundColor(fg.opacity(0.8))
        }

        // The menubar is translucent and shows the desktop wallpaper, and its tint tracks the
        // wallpaper (not the system light/dark), so baked colors wash out on a mismatched
        // background. A contrasting halo keeps the text legible over anything.
        let halo: Color = isDark ? .black.opacity(0.6) : .white.opacity(0.7)
        let content = label
            .shadow(color: halo, radius: 1.2)
            .shadow(color: halo, radius: 0.8)
            .padding(.horizontal, 2)
            .padding(.bottom, 1)
        let renderer = ImageRenderer(content: content)
        // Match the actual display: a hardcoded 2 renders soft on a 3x panel and wastes
        // pixels on a 1x one.
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        // The label is a flat bitmap, so without this VoiceOver announces nothing at all.
        image.accessibilityDescription = menuBarAccessibilityLabel
        menuImageCache = (key, image)
        return image
    }

    private var menuBarAccessibilityLabel: String {
        var parts = ["Net worth \(menuValue)"]
        if let change = menuChange {
            let pct = change.text.dropFirst()   // strip the ▲/▼ glyph
            parts.append("\(change.up ? "up" : "down") \(pct) today")
        }
        if !privacyMode, let latest = latestActivityCompact {
            parts.append("latest activity \(latest)")
        }
        if unseenActivityCount > 0 {
            parts.append("\(unseenActivityCount) unseen")
        }
        if errorMessage != nil { parts.append("refresh error") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Privacy-aware formatting

    func money(_ value: Double, _ code: String) -> String {
        privacyMode ? "$•••••" : Self.fullCurrency(value, code: code)
    }

    func moneyCompact(_ value: Double, _ code: String) -> String {
        privacyMode ? "$•••" : Self.compactCurrency(value, code: code)
    }

    // Amounts already stated to be in the base currency — net worth, day change, trend
    // deltas. These take the bare symbol: NumberFormatter renders USD as "US$3,353.25" on
    // any non-US locale, which looks wrong on the headline figure and disagrees with the
    // menubar showing "$3.4k" for that same number. Per-account and per-position rows keep
    // money()/fullCurrency, where the code genuinely disambiguates CAD from USD.
    func baseMoney(_ value: Double) -> String {
        privacyMode ? "$•••••" : Self.baseCurrencyString(value, code: config.baseCurrency)
    }

    static func baseCurrencyString(_ value: Double, code: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        fmt.minimumFractionDigits = 2
        fmt.maximumFractionDigits = 2
        let magnitude = abs(value)
        let body = fmt.string(from: NSNumber(value: magnitude)) ?? String(format: "%.2f", magnitude)
        return (value < 0 ? "-" : "") + currencySymbol(for: code) + body
    }

    // MARK: - Config

    func reloadConfig() {
        SylvesterConfig.ensureExists()
        guard let cfg = SylvesterConfig.load() else {
            phase = .needsConfig("Config file is unreadable — fix \(SylvesterConfig.path.path)")
            return
        }
        config = cfg
        // Anyone already holding a working session predates onboarding — don't walk an
        // existing install back through a first-run wizard on upgrade. Strictly one-shot:
        // if this ran on every config reload it would also undo "Run Setup Again".
        if !UserDefaults.standard.bool(forKey: "sylvester.onboardingMigrated") {
            UserDefaults.standard.set(true, forKey: "sylvester.onboardingMigrated")
            if cfg.hasOAuthSession || (cfg.hasPartnerCreds && cfg.hasUser) {
                onboardingComplete = true
            }
        }
        if cfg.mode == .personal {
            // Personal keys don't paste creds — they sign in via OAuth (browser).
            if cfg.hasOAuthSession {
                phase = .ready
                Task { await refresh() }
            } else {
                phase = .needsConfig("Sign in with SnapTrade to connect your personal key.")
            }
            return
        }
        if !cfg.hasPartnerCreds {
            phase = .needsConfig("Add clientId + consumerKey to config, then reload.")
        } else if !cfg.hasUser {
            phase = .needsConfig("Partner creds OK. Register a SnapTrade user (or paste an existing userId/userSecret into config).")
        } else {
            phase = .ready
            Task { await refresh() }
        }
    }

    func openConfig() {
        SylvesterConfig.ensureExists()
        NSWorkspace.shared.open(SylvesterConfig.path)
    }

    @Published var setupBusy = false
    // Re-opens the key wizard from the ⋯ menu even when already configured (key rotation).
    @Published var showSetup = false

    // Wizard field drafts live here, NOT as @State in the view: the MenuBarExtra window
    // tears down its view (and all its @State) whenever it loses focus — e.g. when you
    // switch to the browser to copy your key — so form input must survive on the
    // persistent AppState or it's wiped every time the popover reopens.
    @Published var draftClientId = ""
    @Published var draftConsumerKey = ""
    @Published var draftUserId = ""
    @Published var draftUserSecret = ""
    @Published var draftAdvanced = false
    private var setupDraftSeeded = false

    // Seed drafts from config once per wizard session; guarded so a reopen never clobbers
    // what's been typed. (Fresh setup: config is empty → drafts stay empty.)
    func seedSetupDraftIfNeeded() {
        guard !setupDraftSeeded else { return }
        draftClientId = config.clientId
        draftConsumerKey = config.consumerKey
        draftUserId = config.userId
        setupDraftSeeded = true
    }

    // Explicit close (Cancel / successful setup) — clears drafts so the next open re-seeds
    // from the current config. NOT called when the popover merely loses focus.
    func dismissSetup() {
        showSetup = false
        setupDraftSeeded = false
        draftClientId = ""
        draftConsumerKey = ""
        draftUserId = ""
        draftUserSecret = ""
        draftAdvanced = false
    }

    // Wizard path: validate pasted partner creds, persist (secrets -> keychain),
    // register a user if none supplied, then go live.
    func completeSetup(clientId: String, consumerKey: String, userId: String, userSecret: String) async {
        let cid = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = consumerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty, !key.isEmpty else {
            errorMessage = "clientId and consumerKey are both required."
            return
        }
        setupBusy = true
        defer { setupBusy = false }

        let probe = SnapTradeClient(clientId: cid, consumerKey: key)
        do {
            _ = try await probe.listUsers()
        } catch {
            errorMessage = "Key check failed — \(error.localizedDescription)"
            return
        }

        config.clientId = cid
        config.consumerKey = key
        config.userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        config.userSecret = userSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainStore.set("consumerKey", key)   // activates keychain mode before save
        do {
            try config.save()
        } catch {
            errorMessage = "Couldn't save config: \(error.localizedDescription)"
            return
        }
        errorMessage = nil

        if config.hasUser {
            phase = .ready
            await refresh()
        } else {
            await registerUser()
        }
        if case .ready = phase, errorMessage == nil {
            dismissSetup()
        }
    }

    func moveKeysToKeychain() {
        do {
            try config.moveSecretsToKeychain()
            errorMessage = nil
        } catch {
            errorMessage = "Keychain move failed: \(error.localizedDescription)"
        }
    }

    var secretsInKeychain: Bool {
        KeychainStore.get("consumerKey") != nil
    }

    // MARK: - Launch at login

    // SMAppService registers the bundle itself, so it needs a real .app — a bare
    // `swift run` binary has no bundle id and can't be a login item.
    var canLaunchAtLogin: Bool { Bundle.main.bundleIdentifier != nil }

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginPermission: PermissionStatus =
        PermissionStatus(loginItem: SMAppService.mainApp.status)

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't \(enabled ? "enable" : "disable") launch at login — \(error.localizedDescription)"
        }
        // Re-read rather than trusting the requested value: registration can land in
        // .requiresApproval, where the toggle is on for us but off until the user says so.
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        launchAtLoginPermission = PermissionStatus(loginItem: status)
        if enabled, status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Permissions

    @Published var notificationPermission: PermissionStatus = .notRequested

    func refreshPermissions() async {
        await Notifier.shared.refreshAuthorization()
        notificationPermission = PermissionStatus(notification: Notifier.shared.authorization)
        launchAtLoginPermission = PermissionStatus(loginItem: SMAppService.mainApp.status)
    }

    func requestNotificationPermission() async {
        // First ask shows the system prompt; every later one is a silent no-op, so once
        // denied the only way forward is the Notifications pane.
        if notificationPermission == .denied {
            Notifier.shared.openSystemSettings()
            return
        }
        _ = await Notifier.shared.requestAuthorization()
        await refreshPermissions()
    }

    // MARK: - Onboarding

    // Four steps: welcome, connect SnapTrade, permissions, link a brokerage.
    static let onboardingSteps = 4

    @Published var onboardingStep = 0
    @Published var onboardingComplete = UserDefaults.standard.bool(forKey: "sylvester.onboarded") {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "sylvester.onboarded") }
    }

    func advanceOnboarding() {
        if onboardingStep >= Self.onboardingSteps - 1 {
            onboardingComplete = true
        } else {
            onboardingStep += 1
        }
    }

    func finishOnboarding() {
        onboardingComplete = true
    }

    // MARK: - Personal-key OAuth

    // Browser sign-in for personal keys: register a public OAuth client once, run the
    // authorization-code flow, and store the bearer + refresh tokens. No key paste — the
    // dashboard login resolves the personal partner + user on the server.
    func signInWithSnapTrade() async {
        setupBusy = true
        defer { setupBusy = false }
        let oauth = makeOAuthClient()
        do {
            let clientId: String
            if let existing = config.oauthClientId, !existing.isEmpty {
                clientId = existing
            } else {
                clientId = try await oauth.registerClient(clientName: "Sylvester")
                config.oauthClientId = clientId
            }
            let tokens = try await oauth.authorize(clientId: clientId)
            config.authMode = AuthMode.personal.rawValue
            config.accessToken = tokens.accessToken
            config.refreshToken = tokens.refreshToken
            config.accessTokenExpiry = tokens.expiry.timeIntervalSince1970
            // Personal OAuth ignores partner creds — clear any leftovers (incl. Keychain).
            config.clientId = ""
            config.consumerKey = ""
            config.userId = ""
            config.userSecret = ""
            KeychainStore.delete("consumerKey")
            KeychainStore.delete("userSecret")
            try config.save()
            errorMessage = nil
            phase = .ready
            dismissSetup()
            // Mid-onboarding this is step 2 clearing, not the end of setup — move to the
            // permissions step rather than dropping the user into the dashboard.
            if !onboardingComplete, onboardingStep <= 1 {
                onboardingStep = 2
                await refreshPermissions()
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Refresh the access token when missing/near expiry. false => unrecoverable (re-sign-in).
    private func ensureFreshTokenIfNeeded() async -> Bool {
        guard config.mode == .personal else { return true }
        let now = Date().timeIntervalSince1970
        let valid = !(config.accessToken ?? "").isEmpty && (config.accessTokenExpiry ?? 0) - now > 300
        if valid { return true }
        guard let refreshToken = config.refreshToken, !refreshToken.isEmpty,
              let clientId = config.oauthClientId, !clientId.isEmpty else { return false }
        do {
            let tokens = try await makeOAuthClient().refresh(refreshToken: refreshToken, clientId: clientId)
            config.accessToken = tokens.accessToken
            config.refreshToken = tokens.refreshToken     // rotated — must persist the new one
            config.accessTokenExpiry = tokens.expiry.timeIntervalSince1970
            try config.save()
            return true
        } catch {
            return false
        }
    }

    func signOutPersonal() {
        cancelConnectWatch()
        config.clearOAuthSession()
        try? config.save()
        groups = []
        details = [:]
        netWorth = 0
        attentionConnections = []
        phase = .needsConfig("Signed out — sign in with SnapTrade to reconnect.")
    }

    // MARK: - Actions

    func registerUser() async {
        guard config.hasPartnerCreds else { return }
        do {
            let userId = config.userId.isEmpty
                ? "sylvester-\(UUID().uuidString.prefix(8).lowercased())"
                : config.userId
            let resp = try await client.registerUser(userId: userId)
            config.userId = resp.userId
            config.userSecret = resp.userSecret
            try config.save()
            errorMessage = nil
            phase = .ready
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Connect

    // True from the moment the portal opens until a connection shows up (or we give up).
    @Published var awaitingConnection = false
    private var connectWatchTask: Task<Void, Never>?

    // Opens the SnapTrade connection portal in the browser to link a brokerage.
    func connectAccount() async {
        do {
            let before = await currentAuthorizations()
            let url = try await client.connectURL(userId: config.userId, userSecret: config.userSecret)
            NSWorkspace.shared.open(url)
            errorMessage = nil
            watchForConnectionChange(
                knownIds: Set(before.map(\.id)),
                disabledIds: Set(before.filter { $0.disabled == true }.map(\.id))
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentAuthorizations() async -> [STAuthorization] {
        (try? await client.listAuthorizations(
            userId: config.userId, userSecret: config.userSecret)) ?? []
    }

    // The portal is a browser round-trip with no callback, so nothing tells us when the
    // user is done. Without this, a finished connection only surfaces when the popover is
    // next reopened — and schedulePendingPoll() can't cover it, because it only schedules
    // itself once a pending connection is already visible.
    //
    // So poll for the authorization itself. That record appears the moment the portal
    // completes — minutes before the first holdings sync lands — which is exactly what's
    // worth showing: the brokerage name, listed, syncing.
    private func watchForConnectionChange(knownIds: Set<String>, disabledIds: Set<String>) {
        connectWatchTask?.cancel()
        awaitingConnection = true
        connectWatchTask = Task { [weak self] in
            // Backs off 2s -> 10s and gives up after ~4 minutes, so a portal tab that got
            // abandoned doesn't leave us polling for the rest of the session.
            var delay = 2.0
            var elapsed = 0.0
            while elapsed < 240 {
                try? await Task.sleep(for: .seconds(delay))
                elapsed += delay
                delay = min(delay * 1.4, 10)
                guard !Task.isCancelled, let self else { return }
                guard case .ready = phase else { continue }

                let auths = await currentAuthorizations()
                let appeared = auths.contains { !knownIds.contains($0.id) }
                // A reconnect reuses the existing id, so watch for revival too.
                let revived = auths.contains { disabledIds.contains($0.id) && $0.disabled != true }
                if appeared || revived {
                    await connectionDetected()
                    return
                }
            }
            self?.awaitingConnection = false
        }
    }

    private func connectionDetected() async {
        awaitingConnection = false
        connectWatchTask = nil
        // Pulls the connection into the list right away — it renders as the brokerage name
        // with "first sync running…", rather than nothing at all for several minutes.
        await refresh(fullDetails: false)
        // This is onboarding's last step; finishing drops the user straight into the
        // dashboard with their new connection already showing.
        if !onboardingComplete { finishOnboarding() }
    }

    // Posts one of each kind so both paths can be checked in a single click: the routine
    // one is passive and silent with the three-line layout, the attention one plays a
    // sound and carries the Reconnect button. They also carry different thread ids, so in
    // Notification Center they should file into two separate groups rather than one.
    func sendTestNotifications() async {
        let stamp = Int(Date().timeIntervalSince1970)
        Notifier.shared.post(
            id: "test-activity-\(stamp)",
            title: "Dividend · VFV",
            subtitle: money(12.34, config.baseCurrency),
            body: "Example account · test notification",
            kind: .activity
        )
        // Use a real authorization id when there is one, so Reconnect genuinely exercises
        // the action handler rather than just rendering a button that does nothing.
        var authId = attentionConnections.first?.id
        if authId == nil { authId = await currentAuthorizations().first?.id }
        Notifier.shared.post(
            id: "test-attention-\(stamp)",
            title: "Example connection disconnected",
            subtitle: "Test only — nothing is actually broken",
            body: "Reconnect opens the SnapTrade portal for a real connection.",
            kind: .attention,
            authorizationId: authId
        )
    }

    func cancelConnectWatch() {
        connectWatchTask?.cancel()
        connectWatchTask = nil
        awaitingConnection = false
    }

    func refresh(fullDetails: Bool = true) async {
        guard case .ready = phase, !isRefreshing else { return }
        // Personal OAuth: make sure the bearer token is fresh before any data calls.
        if config.mode == .personal, !(await ensureFreshTokenIfNeeded()) {
            phase = .needsConfig("Session expired — sign in with SnapTrade again.")
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let accountsCall = client.listAccounts(userId: config.userId, userSecret: config.userSecret)
            async let authsCall = client.listAuthorizations(userId: config.userId, userSecret: config.userSecret)
            let accounts = try await accountsCall
            let auths = (try? await authsCall) ?? []
            let fx = await FXService.converter(base: config.baseCurrency, fallback: config.fxRates)

            self.fx = fx
            rebuildTotals(from: accounts, fx: fx)

            let unconverted = Set(accounts.map(\.currency).filter { !fx.hasRate(for: $0) })
            if !unconverted.isEmpty {
                fxNote = "No FX rate for \(unconverted.sorted().joined(separator: ", ")) — counted 1:1"
            } else if !fx.isLive && !accounts.allSatisfy({ $0.currency == config.baseCurrency }) {
                fxNote = "Live FX unavailable — using config fxRates"
            } else {
                fxNote = nil
            }

            // Surface connections that have no synced accounts yet (or are disabled) —
            // otherwise a fresh/broken connection is just invisibly absent.
            let syncedAuthIds = Set(accounts.compactMap(\.brokerageAuthorization))
            attentionConnections = auths.filter { $0.disabled == true || !syncedAuthIds.contains($0.id) }
            schedulePendingPoll()

            let disabledIds = Set(auths.filter { $0.disabled == true }.map(\.id))
            if let known = knownDisabledAuthIds {
                for auth in auths where auth.disabled == true && !known.contains(auth.id) {
                    Notifier.shared.post(
                        id: "broken-\(auth.id)",
                        title: "\(auth.displayName) disconnected",
                        subtitle: "Sylvester can't refresh its accounts",
                        body: "Reconnect to resume syncing balances and activity.",
                        kind: .attention,
                        authorizationId: auth.id
                    )
                }
            }
            knownDisabledAuthIds = disabledIds

            lastRefresh = Date()
            errorMessage = nil

            await fetchDetails(for: accounts, onlyMissing: !fullDetails)
            // Re-total now that live balances are in; only record history from the live pass.
            rebuildTotals(from: accounts, fx: fx)
            if !accounts.isEmpty {
                HistoryStore.append(value: netWorth, currency: config.baseCurrency, to: &history)
            }
            if fullDetails { await fetchQuotes() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Group accounts by institution and total them in base currency, preferring each
    // account's live-fetched balance over the cached listAccounts snapshot.
    private func rebuildTotals(from accounts: [STAccount], fx: FXConverter) {
        let effective = accounts.map { account -> STAccount in
            guard let live = details[account.id]?.liveBalance else { return account }
            var updated = account
            updated.balance = live
            return updated
        }
        var byInstitution: [String: [STAccount]] = [:]
        for account in effective {
            byInstitution[account.institutionName ?? "Other", default: []].append(account)
        }
        groups = byInstitution
            .map { name, accts in
                InstitutionGroup(
                    name: name,
                    accounts: accts.sorted { $0.amount > $1.amount },
                    totalInBase: accts.reduce(0) { $0 + fx.toBase($1.amount, from: $1.currency) }
                )
            }
            .sorted { $0.totalInBase > $1.totalInBase }
        netWorth = groups.reduce(0) { $0 + $1.totalInBase }
        // Expansion state outlives the view now, so drop rows that no longer exist
        // (connection removed, account closed) instead of holding their ids forever.
        expandedAccounts.formIntersection(Set(effective.map(\.id)))
    }

    // Event-driven refresh when the user reopens the popover (e.g. after finishing a browser
    // reconnect) — picks up changes without a background polling loop. Throttled so rapid
    // reopens don't hammer the API; always refreshes while a connection needs attention.
    func refreshOnReopen() async {
        guard case .ready = phase, !isRefreshing else { return }
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > 45 } ?? true
        if stale || !attentionConnections.isEmpty {
            await refresh(fullDetails: false)
        }
    }

    // MARK: - Quotes / day change

    private func fetchQuotes() async {
        let tickers = Set(details.values.flatMap { $0.positions.map(\.ticker) })
            .filter { $0 != "?" && !$0.isEmpty }
        guard !tickers.isEmpty else {
            quotes = [:]
            return
        }
        let fresh = await QuoteService.fetch(Array(tickers))
        if !fresh.isEmpty { quotes = fresh }
    }

    // Market day change across all quoted positions, in base currency.
    var marketDayChange: (delta: Double, pct: Double)? {
        guard let fx, !quotes.isEmpty else { return nil }
        var change = 0.0
        var quotedAny = false
        for detail in details.values {
            for position in detail.positions {
                guard let quote = quotes[position.ticker], quote.prevClose > 0 else { continue }
                quotedAny = true
                change += fx.toBase((quote.price - quote.prevClose) * position.quantity, from: position.currencyCode)
            }
        }
        guard quotedAny else { return nil }
        let baseline = netWorth - change
        return (change, baseline != 0 ? change / abs(baseline) * 100 : 0)
    }

    func dayChangePct(_ position: STPosition) -> Double? {
        quotes[position.ticker]?.dayChangePct
    }

    // Total return percent from broker-reported open PnL vs cost basis.
    func pnlPct(_ position: STPosition) -> Double? {
        guard let pnl = position.openPnl, position.value != 0 else { return nil }
        let basis = position.value - pnl
        return basis > 0 ? pnl / basis * 100 : nil
    }

    // Dated external cash flows (contributions/withdrawals) in base currency, oldest first.
    func flowEvents(since: Date) -> [(date: Date, amount: Double)] {
        guard let fx else { return [] }
        return activities
            .compactMap { activity -> (Date, Double)? in
                let type = (activity.type ?? "").uppercased()
                guard type == "CONTRIBUTION" || type == "WITHDRAWAL",
                      let date = activity.date, date >= since,
                      let amount = activity.amount, amount != 0
                else { return nil }
                return (date, fx.toBase(amount, from: activity.currencyCode))
            }
            .sorted { $0.0 < $1.0 }
            .map { (date: $0.0, amount: $0.1) }
    }

    // While a first sync is pending, re-poll every 20s so the account pops in on its own.
    // Light refresh: details only for accounts we don't have yet.
    private func schedulePendingPoll() {
        pendingPollTask?.cancel()
        guard attentionConnections.contains(where: { $0.disabled != true }) else { return }
        pendingPollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.refresh(fullDetails: false)
        }
    }

    func removeConnection(id: String) async {
        do {
            try await client.deleteAuthorization(id: id, userId: config.userId, userSecret: config.userSecret)
            errorMessage = nil
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Change vs the first recorded point of today (or the earliest point as fallback).
    var sessionDelta: (delta: Double, pct: Double)? {
        let points = history.filter { $0.c == config.baseCurrency }
        guard points.count >= 2, let last = points.last, let first = points.first else { return nil }
        let baseline = points.first(where: { Calendar.current.isDateInToday($0.date) }) ?? first
        guard baseline.t < last.t else { return nil }
        let delta = last.v - baseline.v
        return (delta, baseline.v != 0 ? delta / abs(baseline.v) * 100 : 0)
    }

    // MARK: - Activities

    private func processActivities(_ fresh: [STActivity]) {
        let now = Date().timeIntervalSince1970
        // First-ever fetch: baseline everything so 30 days of history isn't "new".
        let isBaseline = !seenActivities.baselined
        var newArrivals: [STActivity] = []
        for activity in fresh where seenActivities.firstSeen[activity.id] == nil {
            seenActivities.firstSeen[activity.id] = isBaseline ? 0 : now
            if !isBaseline { newArrivals.append(activity) }
        }
        seenActivities.baselined = true
        notifyNewActivities(newArrivals)
        // Prune ids that fell out of the fetch window a while ago.
        let cutoff = now - 90 * 86_400
        seenActivities.firstSeen = seenActivities.firstSeen.filter { $0.value == 0 ? true : $0.value > cutoff }
        SeenActivitiesStore.save(seenActivities)

        activities = fresh.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let lastViewed = activitiesLastViewed
        unseenActivityCount = fresh.filter {
            let t = seenActivities.firstSeen[$0.id] ?? 0
            return t > 0 && t > lastViewed
        }.count
    }

    // One notification per genuinely-new activity; a digest when several land at once.
    // Routine money movement is posted passively — it belongs in Notification Center, not
    // in front of whatever you're doing.
    private func notifyNewActivities(_ fresh: [STActivity]) {
        guard !fresh.isEmpty else { return }
        if fresh.count > 3 {
            let listed = fresh.prefix(4)
                .map { ActivityFeedView.title(for: $0, privacy: privacyMode) }
                .joined(separator: " · ")
            let remainder = fresh.count - 4
            // The net figure is the one thing a digest can say that the individual
            // notifications can't — four trades that cancel out is a different morning
            // from four that don't.
            let net = fx.map { converter in
                fresh.reduce(0.0) { $0 + converter.toBase($1.amount ?? 0, from: $1.currencyCode) }
            }
            Notifier.shared.post(
                id: "acts-\(Int(Date().timeIntervalSince1970))",
                title: "\(fresh.count) new activities",
                subtitle: net.map { "net \($0 >= 0 ? "+" : "")\(baseMoney($0))" } ?? "",
                body: remainder > 0 ? "\(listed) · +\(remainder) more" : listed,
                kind: .activity
            )
            return
        }
        for activity in fresh {
            // Amount on the subtitle line, account on the body: macOS renders all three,
            // and the amount is what you actually want to read at a glance.
            let amount = activity.amount ?? 0
            Notifier.shared.post(
                id: "act-\(activity.id)",
                title: ActivityFeedView.title(for: activity, privacy: privacyMode),
                subtitle: amount != 0 ? money(amount, activity.currencyCode) : "",
                body: activity.account?.name ?? activity.account?.institutionName ?? "",
                kind: .activity
            )
        }
    }

    // Arrived after baseline, within the last 48h — gets the NEW dot.
    func isNewActivity(_ activity: STActivity) -> Bool {
        let t = seenActivities.firstSeen[activity.id] ?? 0
        return t > 0 && Date().timeIntervalSince1970 - t < 48 * 3600
    }

    func markActivitiesViewed() {
        activitiesLastViewed = Date().timeIntervalSince1970
        unseenActivityCount = 0
    }

    static func dateString(daysAgo: Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    func reconnect(_ auth: STAuthorization) async {
        await reconnectAuthorization(id: auth.id)
    }

    // Takes a bare id so a notification action — which only carries the id in userInfo,
    // not the whole authorization — can drive the same flow as the in-app button.
    func reconnectAuthorization(id: String) async {
        do {
            let before = await currentAuthorizations()
            let url = try await client.connectURL(
                userId: config.userId, userSecret: config.userSecret, reconnect: id)
            NSWorkspace.shared.open(url)
            errorMessage = nil
            // Same browser round-trip, same lack of a callback — watch for the revival
            // rather than making the user come back and check.
            watchForConnectionChange(
                knownIds: Set(before.map(\.id)),
                disabledIds: Set(before.filter { $0.disabled == true }.map(\.id))
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Prefetch positions + cash for every account in parallel so expanding a row is instant.
    private func fetchDetails(for accounts: [STAccount], onlyMissing: Bool = false) async {
        let client = self.client
        let userId = config.userId
        let userSecret = config.userSecret

        let targets = onlyMissing
            ? accounts.filter { details[$0.id] == nil || details[$0.id]?.error != nil }
            : accounts

        let currentIds = Set(accounts.map(\.id))
        if targets.isEmpty {
            details = details.filter { currentIds.contains($0.key) }
            return
        }

        let fetched = await withTaskGroup(of: (String, AccountDetail).self) { group in
            for account in targets {
                group.addTask {
                    var detail = AccountDetail()
                    async let liveAccount = client.accountDetail(
                        accountId: account.id, userId: userId, userSecret: userSecret)
                    do {
                        async let positions = client.positions(
                            accountId: account.id, userId: userId, userSecret: userSecret)
                        async let balances = client.balances(
                            accountId: account.id, userId: userId, userSecret: userSecret)
                        async let activities = client.accountActivities(
                            accountId: account.id, userId: userId, userSecret: userSecret,
                            startDate: Self.dateString(daysAgo: 30))
                        detail.positions = try await positions.sorted { $0.value > $1.value }
                        detail.cashByCurrency = try await balances
                            .compactMap { bal -> (String, Double)? in
                                guard let cash = bal.cash, abs(cash) > 0.005 else { return nil }
                                return (bal.currency?.code ?? "?", cash)
                            }
                            .sorted { $0.1 > $1.1 }
                        // Per-account response has no nested account; inject for the feed.
                        detail.activities = try await activities.map { activity in
                            var a = activity
                            a.account = STActivity.Account(
                                id: account.id,
                                name: account.displayName,
                                number: nil,
                                institutionName: account.institutionName
                            )
                            return a
                        }
                    } catch {
                        detail.error = error.localizedDescription
                    }
                    // Non-fatal; a nil total means the server itself fell back to an
                    // empty cache — keep the listAccounts value rather than zeroing.
                    if let live = (try? await liveAccount)?.balance, live.total?.amount != nil {
                        detail.liveBalance = live
                    }
                    return (account.id, detail)
                }
            }
            var result: [String: AccountDetail] = [:]
            for await (id, detail) in group {
                result[id] = detail
            }
            return result
        }

        // Merge, never letting a failed fetch clobber last-known-good data —
        // a transient error would otherwise flap the allocation pie to Unclassified.
        var merged = details
        for (id, detail) in fetched {
            if detail.error != nil, let old = merged[id], old.error == nil { continue }
            var next = detail
            // A previous refresh's live balance beats falling back to the daily snapshot.
            if next.liveBalance == nil { next.liveBalance = merged[id]?.liveBalance }
            merged[id] = next
        }
        details = merged.filter { currentIds.contains($0.key) }
        processActivities(details.values.flatMap(\.activities))
    }

    // MARK: - Allocation

    enum AllocationDimension: String, CaseIterable, Identifiable {
        case asset = "Asset"
        case account = "Account"
        case currency = "Currency"
        var id: String { rawValue }
    }

    struct AllocationSlice: Identifiable {
        var name: String
        var value: Double
        var id: String { name }
    }

    // Aggregate holdings into base-currency slices for the pie, top N + Other.
    func allocation(by dimension: AllocationDimension, topN: Int = 8) -> [AllocationSlice] {
        guard let fx else { return [] }
        var totals: [String: Double] = [:]
        switch dimension {
        case .asset:
            for group in groups {
                for account in group.accounts {
                    if let detail = details[account.id], detail.error == nil,
                       !(detail.positions.isEmpty && detail.cashByCurrency.isEmpty) {
                        for p in detail.positions {
                            totals[p.ticker, default: 0] += fx.toBase(p.value, from: p.currencyCode)
                        }
                        for cash in detail.cashByCurrency {
                            totals["Cash", default: 0] += fx.toBase(cash.amount, from: cash.code)
                        }
                    } else {
                        // No position data for this account — count its balance as one lump.
                        totals["Unclassified", default: 0] += fx.toBase(account.amount, from: account.currency)
                    }
                }
            }
        case .account:
            for group in groups {
                for account in group.accounts {
                    totals[account.displayName, default: 0] += fx.toBase(account.amount, from: account.currency)
                }
            }
        case .currency:
            for group in groups {
                for account in group.accounts {
                    totals[account.currency, default: 0] += fx.toBase(account.amount, from: account.currency)
                }
            }
        }

        let sorted = totals.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }
        var slices = sorted.prefix(topN).map { AllocationSlice(name: $0.key, value: $0.value) }
        let rest = sorted.dropFirst(topN).reduce(0.0) { $0 + $1.value }
        if rest > 0 { slices.append(AllocationSlice(name: "Other", value: rest)) }
        return slices
    }

    // MARK: - Formatting

    private static var symbolCache: [String: String] = [:]

    // Compact prefix for the menubar and chart axes. NumberFormatter's currencySymbol
    // property tracks the *locale*, not the currencyCode you set — so render a sentinel
    // and strip it to get the symbol for an arbitrary code (GBP -> "£", not "GBP ").
    static func currencySymbol(for code: String) -> String {
        if let cached = symbolCache[code] { return cached }
        let symbol: String
        switch code {
        // The dollar family all render as "$": the base currency is stated once in the
        // UI, so the prefix doesn't have to disambiguate them, and "CA$12.3k" in a
        // menubar is noise.
        case "USD", "CAD", "AUD", "NZD", "SGD", "HKD":
            symbol = "$"
        default:
            let fmt = NumberFormatter()
            fmt.numberStyle = .currency
            fmt.currencyCode = code
            // Pin the locale so the symbol stays a prefix regardless of system region.
            fmt.locale = Locale(identifier: "en_US")
            fmt.minimumFractionDigits = 0
            fmt.maximumFractionDigits = 0
            let raw = (fmt.string(from: 0) ?? code)
                .replacingOccurrences(of: "0", with: "")
                .trimmingCharacters(in: .whitespaces)
            let resolved = raw.isEmpty ? code : raw
            // Alphabetic fallbacks (CHF, or an unrecognized code echoed back) need a
            // space so they don't run into the number.
            symbol = resolved.last?.isLetter == true ? "\(resolved) " : resolved
        }
        symbolCache[code] = symbol
        return symbol
    }

    static func compactCurrency(_ value: Double, code: String) -> String {
        let symbol = currencySymbol(for: code)
        let v = abs(value)
        let body: String
        switch v {
        case 1_000_000...: body = String(format: "%.2fM", v / 1_000_000)
        case 100_000...: body = String(format: "%.0fk", v / 1_000)
        case 1_000...: body = String(format: "%.1fk", v / 1_000)
        default: body = String(format: "%.0f", v)
        }
        return (value < 0 ? "-" : "") + symbol + body
    }

    static func fullCurrency(_ value: Double, code: String) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = code
        fmt.maximumFractionDigits = 2
        return fmt.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, code)
    }

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 5 { return "just now" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
