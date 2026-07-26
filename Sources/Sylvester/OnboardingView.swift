import AppKit
import SwiftUI

// First-run flow.
//
// It exists mostly to stop macOS ambushing a brand-new user with a stack of system
// prompts before they know what the app is. Most of those prompts can't be suppressed —
// they're the OS asking, not us — but they can stop being ambushes: each one is explained
// immediately before it fires, and the ones that can't be granted in-process get a deep
// link plus something to drag instead of a dead end.
struct OnboardingView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            VStack(alignment: .leading, spacing: 11) {
                switch state.onboardingStep {
                case 0: welcome
                case 1: connect
                case 2: permissions
                default: brokerage
                }
            }
            .padding(14)
            .frame(minHeight: 268, alignment: .top)
        }
        .task { await state.refreshPermissions() }
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 19, height: 19)
            Text("Set up Sylvester").font(.headline)
            Spacer()
            HStack(spacing: 4) {
                ForEach(0..<AppState.onboardingSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= state.onboardingStep ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == state.onboardingStep ? 12 : 5, height: 5)
                }
            }
            .animation(.easeOut(duration: 0.18), value: state.onboardingStep)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func stepTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.rowTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(Theme.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .controlSize(.large)
    }

    // MARK: - Step 0 · Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 11) {
            stepTitle(
                "Your net worth, every brokerage, in the menubar.",
                "Four quick steps. Nothing leaves this Mac."
            )
            VStack(alignment: .leading, spacing: 8) {
                bullet("lock.fill", "Tokens live in your Keychain. Balances are pulled straight from SnapTrade — there's no Sylvester server.")
                bullet("eye.slash.fill", "Read-only access. Sylvester can't place trades or move money.")
                bullet("bell.badge.fill", "macOS will ask for a couple of permissions. We'll explain each one first.")
            }
            Spacer(minLength: 0)
            primaryButton("Get Started") { state.advanceOnboarding() }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
                .frame(width: 15)
            Text(text)
                .font(Theme.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 1 · Connect SnapTrade

    private var connect: some View {
        VStack(alignment: .leading, spacing: 11) {
            stepTitle(
                "Connect your SnapTrade account",
                "Sylvester uses a personal key: your browser opens, you approve read access, and the token comes straight back here. Nothing to copy or paste."
            )

            Button {
                Task { await state.signInWithSnapTrade() }
            } label: {
                HStack(spacing: 6) {
                    if state.setupBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.badge.key.fill")
                    }
                    Text(state.setupBusy ? "Waiting for browser sign-in…" : "Sign in with SnapTrade")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.large)
            .disabled(state.setupBusy)

            Button {
                NSWorkspace.shared.open(URL(string: "https://snaptrade.com")!)
            } label: {
                Text("Don't have a SnapTrade account? Create one free")
                    .font(Theme.micro)
            }
            .buttonStyle(.link)

            // Pre-announcing this prompt is the whole trick. The loopback listener that
            // catches the OAuth redirect makes macOS ask whether to accept incoming
            // connections — which, arriving unexplained mid-sign-in on a finance app,
            // reads alarming. Said first, it reads as expected.
            noteBox(
                "wifi.exclamationmark",
                "macOS may ask to allow incoming network connections. That's Sylvester catching the sign-in redirect on 127.0.0.1 — local only, and it closes as soon as sign-in completes."
            )

            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Use an API key instead") { state.showSetup = true }
                    .font(Theme.micro)
                    .buttonStyle(.link)
                Spacer()
                Button("Skip") { state.advanceOnboarding() }
                    .controlSize(.small)
            }
        }
    }

    private func noteBox(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(Theme.micro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
    }

    // MARK: - Step 2 · Permissions

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 11) {
            stepTitle(
                "Two optional permissions",
                "Neither is required to see your balances, and both can be changed later from the ⋯ menu."
            )

            permissionRow(
                symbol: "bell.badge.fill",
                title: "Notifications",
                detail: "Tells you when a dividend, trade, or deposit lands — and when a brokerage connection breaks.",
                status: state.notificationPermission
            ) {
                Task { await state.requestNotificationPermission() }
            }

            permissionRow(
                symbol: "power",
                title: "Launch at Login",
                detail: "Sylvester starts with your Mac and waits in the menubar.",
                status: state.launchAtLoginPermission
            ) {
                if state.launchAtLoginPermission == .needsApproval {
                    state.openLoginItemsSettings()
                } else {
                    state.setLaunchAtLogin(true)
                }
            }

            if state.launchAtLoginPermission == .needsApproval {
                dragTarget
            }

            Spacer(minLength: 0)
            HStack {
                Button("Skip") { state.advanceOnboarding() }
                    .controlSize(.small)
                Spacer()
                Button("Continue") { state.advanceOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .controlSize(.small)
            }
        }
        // Approving in System Settings doesn't call back into the app, so re-read on
        // return rather than leaving a stale "needs approval" on screen.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await state.refreshPermissions() }
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        status: PermissionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(status == .granted ? Color.accentColor : Color.secondary)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(Theme.label.weight(.semibold))
                    Image(systemName: status.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(status.tint)
                }
                Text(detail)
                    .font(Theme.micro)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(status.actionTitle, action: action)
                .controlSize(.small)
                .disabled(status == .granted)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
    }

    // The Spokenly move. When SMAppService lands in .requiresApproval, the Login Items
    // pane has no "approve" button for an app that isn't listed yet — the only way in is
    // to drag the bundle into the list. Telling someone to go find Sylvester in Finder and
    // drag it is a dead end mid-onboarding, so hand them the icon right here.
    private var dragTarget: some View {
        HStack(spacing: 11) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
                .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag this icon into the list")
                    .font(Theme.label.weight(.medium))
                Text("System Settings is open to Login Items. Drop Sylvester under “Open at Login”, then come back — this updates on its own.")
                    .font(Theme.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: - Step 3 · Link a brokerage

    private var brokerage: some View {
        VStack(alignment: .leading, spacing: 11) {
            stepTitle(
                "Link your first brokerage",
                "The SnapTrade connection portal opens in your browser. Sylvester picks the connection up as soon as you finish there — no need to sit through the first sync."
            )

            Button {
                Task { await state.connectAccount() }
            } label: {
                Label("Connect Account", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .controlSize(.large)
            .disabled(!state.config.hasUser && state.config.mode != .personal)

            if state.awaitingConnection {
                HStack(alignment: .top, spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to finish in the browser — this moves on by itself the moment the connection lands. You don't have to wait for the sync.")
                        .font(Theme.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.micro)
                    .foregroundStyle(Theme.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            HStack {
                Button("Back") { state.onboardingStep = 2 }
                    .controlSize(.small)
                Spacer()
                Button("Done") { state.finishOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .controlSize(.small)
            }
        }
    }
}
