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
struct SnapBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            if let label = state.menuBarImage() {
                Image(nsImage: label)
            } else {
                Text("SnapBar")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
