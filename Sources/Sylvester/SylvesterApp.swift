import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
        Notifier.shared.setup()
    }
}

@main
struct SylvesterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    // Runs before the StateObject's autoclosure is first evaluated, which matters:
    // AppState.init reads config and Keychain straight away, and would otherwise cache
    // an empty result from before the SnapBar data was carried across.
    init() {
        LegacyMigration.runIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            if let label = state.menuBarImage() {
                Image(nsImage: label)
            } else {
                Text("Sylvester")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
