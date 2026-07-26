import AppKit
import Foundation
import UserNotifications

// File scope rather than static members of Notifier: the delegate callbacks and the Kind
// enum are nonisolated, and reading a @MainActor-isolated static from them is an error
// under Swift 6 concurrency.
private let connectionCategoryId = "sylvester.connection.category"
private let reconnectActionId = "sylvester.reconnect"
private let authorizationInfoKey = "authorizationId"

// Posts macOS notifications. Requires a real .app bundle (bundle id) — when run as a
// bare `swift run` binary, UNUserNotificationCenter is unavailable and this no-ops.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private(set) var available = false

    // Distinct from `available`: the app can be perfectly well bundled and still have the
    // user deny notifications, in which case every post() silently evaporates. Tracked so
    // the UI can say so rather than offering a Test button that appears to do nothing.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    var deliversBanners: Bool {
        available && (authorization == .authorized || authorization == .provisional)
    }

    // Routine money movement vs. something that wants a decision. Drives the sound, how
    // hard macOS presents it, and where it sorts in Notification Center. A dividend
    // landing shouldn't interrupt what you're doing; a dead connection should.
    enum Kind {
        case activity
        case attention

        var threadId: String {
            self == .activity ? "sylvester.activity" : "sylvester.connection"
        }
        // Passive keeps routine notifications out of the way — they file into Notification
        // Center without lighting up the display.
        var interruption: UNNotificationInterruptionLevel {
            self == .activity ? .passive : .active
        }
        var sound: UNNotificationSound? {
            self == .activity ? nil : .default
        }
        var relevance: Double {
            self == .activity ? 0.4 : 1.0
        }
        var category: String? {
            self == .attention ? connectionCategoryId : nil
        }
    }

    // Set by AppState so the banner's Reconnect button can actually do something.
    var onReconnect: ((String) -> Void)?

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        available = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // One actionable category. A broken connection is the only notification with an
        // obvious next step, and taking it straight from the banner saves opening the app
        // to click a button that just opens the browser anyway.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: connectionCategoryId,
                actions: [
                    UNNotificationAction(
                        identifier: reconnectActionId,
                        title: "Reconnect",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])

        // Deliberately NOT requesting authorization here. setup() runs from
        // applicationDidFinishLaunching, so asking now means macOS throws a permission
        // prompt at a brand-new user before a single pixel of Sylvester has been drawn —
        // with no way to know what the app is or why it wants to notify them. Onboarding
        // asks once it has explained itself; refresh the cached status meanwhile.
        Task { await refreshAuthorization() }
    }

    // Returns the resulting status, so the caller can react to a denial immediately
    // rather than polling.
    @discardableResult
    func requestAuthorization() async -> UNAuthorizationStatus {
        guard available else { return .denied }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
        return authorization
    }

    // Once denied, requestAuthorization() is a no-op forever — the only route back is the
    // Notifications pane, so send the user there instead of re-asking into the void.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshAuthorization() async {
        guard available else { return }
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings()
            .authorizationStatus
    }

    // title / subtitle / body map onto the three lines macOS actually renders. Cramming
    // account and amount into a single body line wasted two thirds of the layout.
    func post(
        id: String,
        title: String,
        subtitle: String = "",
        body: String = "",
        kind: Kind = .activity,
        authorizationId: String? = nil
    ) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if !subtitle.isEmpty { content.subtitle = subtitle }
        if !body.isEmpty { content.body = body }
        content.sound = kind.sound
        content.interruptionLevel = kind.interruption
        content.relevanceScore = kind.relevance
        // Groups Sylvester's notifications together instead of interleaving them with
        // everything else that arrived since you last looked.
        content.threadIdentifier = kind.threadId
        if let category = kind.category { content.categoryIdentifier = category }
        if let authorizationId { content.userInfo = [authorizationInfoKey: authorizationId] }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    // Menubar apps count as "frontmost" while the popover is open, which would suppress
    // banners by default — always present. .list also files it in Notification Center, so
    // a banner missed while away from the desk isn't simply lost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // Reconnect from the banner — both the explicit button and a plain click on the
    // notification body, since clicking a "connection broken" alert has no other plausible
    // intent. (A MenuBarExtra popover can't be opened programmatically, so there is
    // nothing else useful a click could do.)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let authId = response.notification.request.content.userInfo[authorizationInfoKey] as? String
        Task { @MainActor [weak self] in
            if let authId,
               action == reconnectActionId || action == UNNotificationDefaultActionIdentifier {
                self?.onReconnect?(authId)
            }
            completionHandler()
        }
    }
}
