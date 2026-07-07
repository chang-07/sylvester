import SwiftUI

private struct RemovalTarget: Identifiable {
    let id: String
    let name: String
}

struct MenuView: View {
    @ObservedObject var state: AppState
    @State private var expanded: Set<String> = []
    @State private var removalTarget: RemovalTarget?
    @AppStorage("snapbar.tab") private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state.phase {
            case .needsConfig(let message):
                setupView(message)
            case .ready:
                if state.showSetup {
                    setupView("")
                } else {
                    readyView
                }
            }
        }
        .frame(width: 340)
        // Refresh when the popover opens (throttled) — event-driven pickup after a reconnect,
        // no background polling. No-op unless ready + stale or a connection needs attention.
        .onAppear { Task { await state.refreshOnReopen() } }
    }

    // MARK: - Setup
    //
    // Field drafts live on AppState (state.draft*), not @State here — the MenuBarExtra
    // window discards this view's state whenever it loses focus.

    // The partner-key section is collapsed by default; this is just a disclosure toggle
    // (no user input), so local @State is fine — re-opened on appear if partner input exists.
    @State private var showPartnerKey = false

    private func setupView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up SnapBar", systemImage: "gearshape")
                .font(.headline)
            Text("Connect your SnapTrade account. Everything stays on this Mac — tokens in the Keychain, data pulled straight from the SnapTrade API.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Primary path: personal-key OAuth. Nothing to paste — sign in via the browser.
            VStack(alignment: .leading, spacing: 4) {
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
                .controlSize(.large)
                .disabled(state.setupBusy)

                Text("Opens your browser to sign in with your SnapTrade account — no API key needed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = state.errorMessage {
                errorBanner(error)
            }

            // Advanced path: classic partner API key (clientId + consumerKey, HMAC + registerUser).
            DisclosureGroup(isExpanded: $showPartnerKey) {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://dashboard.snaptrade.com")!)
                    } label: {
                        Label("Get a key at dashboard.snaptrade.com", systemImage: "arrow.up.right.square")
                            .font(.caption2)
                    }
                    .buttonStyle(.link)

                    TextField("clientId (e.g. YOURNAME-ABCXYZ)", text: $state.draftClientId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    SecureField("consumerKey", text: $state.draftConsumerKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))

                    DisclosureGroup("Already have a SnapTrade user? (optional)", isExpanded: $state.draftAdvanced) {
                        VStack(spacing: 6) {
                            TextField("userId — blank to auto-register", text: $state.draftUserId)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            SecureField("userSecret", text: $state.draftUserSecret)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption2)

                    Button {
                        Task {
                            await state.completeSetup(
                                clientId: state.draftClientId,
                                consumerKey: state.draftConsumerKey,
                                userId: state.draftUserId,
                                userSecret: state.draftUserSecret
                            )
                        }
                    } label: {
                        if state.setupBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Validate & Connect")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.setupBusy || state.draftClientId.isEmpty || state.draftConsumerKey.isEmpty)
                    .padding(.top, 2)
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced: use a partner API key").font(.caption)
            }

            HStack {
                if case .ready = state.phase {
                    Button("Cancel") { state.dismissSetup() }
                        .controlSize(.small)
                }
                Spacer()
                Menu {
                    Button("Open Config File") { state.openConfig() }
                    Button("Reload Config") { state.reloadConfig() }
                    Divider()
                    quitButton
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
        }
        .padding(12)
        .onAppear {
            state.seedSetupDraftIfNeeded()
            if !state.draftClientId.isEmpty { showPartnerKey = true }
        }
    }

    // MARK: - Main

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = state.errorMessage {
                errorBanner(error).padding(.horizontal, 12).padding(.top, 8)
            }
            if let note = state.fxNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            if let target = removalTarget {
                removalConfirm(target)
            }
            Picker("", selection: $tab) {
                Text("Accounts").tag(0)
                Text("Allocation").tag(1)
                Text("Trend").tag(2)
                Text(state.unseenActivityCount > 0 ? "Activity •" : "Activity").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            switch tab {
            case 1:
                AllocationView(state: state).frame(height: allocationHeight)
            case 2:
                TrendView(state: state).frame(height: 268)
            case 3:
                ActivityFeedView(state: state).frame(height: activityHeight)
            default:
                accountList
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Net worth").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if state.isRefreshing {
                    ProgressView().controlSize(.small)
                } else if let last = state.lastRefresh {
                    Text("updated \(AppState.relative(last))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Button {
                    state.privacyMode.toggle()
                } label: {
                    Image(systemName: state.privacyMode ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(state.privacyMode ? "Show amounts" : "Hide amounts (for screenshots)")
            }
            Text(state.money(state.netWorth, state.config.baseCurrency))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            headerDeltaChip
        }
        .padding(12)
    }

    // Prefer live market day-change (vs yesterday's close); fall back to snapshot delta.
    @ViewBuilder
    private var headerDeltaChip: some View {
        if let day = state.marketDayChange {
            let flat = abs(day.delta) < 0.01
            let up = day.delta >= 0
            Text(flat
                ? "flat today"
                : "\(up ? "▲" : "▼") \(state.money(abs(day.delta), state.config.baseCurrency)) (\(String(format: "%.2f", abs(day.pct)))%) today")
                .font(.caption.weight(flat ? .regular : .medium))
                .foregroundStyle(flat ? AnyShapeStyle(.secondary) : AnyShapeStyle(up ? Color.green : Color.red))
        } else if let change = state.sessionDelta {
            let flat = abs(change.delta) < 0.01
            let up = change.delta >= 0
            Text(flat
                ? "flat today"
                : "\(up ? "▲" : "▼") \(state.money(abs(change.delta), state.config.baseCurrency)) (\(String(format: "%.2f", abs(change.pct)))%) today")
                .font(.caption.weight(flat ? .regular : .medium))
                .foregroundStyle(flat ? AnyShapeStyle(.secondary) : AnyShapeStyle(up ? Color.green : Color.red))
        }
    }

    private var accountList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(state.attentionConnections) { auth in
                    connectionRow(auth)
                }
                ForEach(state.groups) { group in
                    groupView(group)
                }
                if state.groups.isEmpty && state.attentionConnections.isEmpty && !state.isRefreshing {
                    VStack(spacing: 8) {
                        Image(systemName: "building.columns")
                            .font(.system(size: 26))
                            .foregroundStyle(.quaternary)
                        Text("Keys are set — now link a brokerage")
                            .font(.callout.weight(.medium))
                        Text("The SnapTrade connection portal opens in your browser; accounts appear here after the first sync.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await state.connectAccount() }
                        } label: {
                            Label("Connect Your First Account", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // ScrollView's ideal height is ~0, so the MenuBarExtra window can't size to it —
        // if the popover opens mid-refresh it collapses and never grows back. Give it an
        // explicit height derived from content instead.
        .frame(height: listHeight)
    }

    // Inline destructive confirm — .alert() doesn't reliably present from a MenuBarExtra window.
    private func removalConfirm(_ target: RemovalTarget) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Remove \(target.name)?")
                .font(.caption.weight(.semibold))
            Text("This unlinks the connection and all of its accounts from SnapTrade.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { removalTarget = nil }
                    .controlSize(.small)
                Button("Remove") {
                    let id = target.id
                    removalTarget = nil
                    Task { await state.removeConnection(id: id) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // Connection with no accounts yet: first-sync pending, stuck, or disabled.
    private func connectionRow(_ auth: STAuthorization) -> some View {
        let disabled = auth.disabled == true
        // A first sync that hasn't produced accounts after 10 min likely died with the
        // connect-time session; only another attended login (reconnect) revives it.
        let stuck = !disabled && (auth.created.map { Date().timeIntervalSince($0) > 600 } ?? false)
        return HStack(alignment: .firstTextBaseline) {
            Image(systemName: disabled ? "exclamationmark.triangle.fill" : "hourglass")
                .font(.caption)
                .foregroundStyle(disabled ? AnyShapeStyle(.red) : AnyShapeStyle(.orange))
            VStack(alignment: .leading, spacing: 0) {
                Text(auth.displayName).font(.callout).lineLimit(1)
                if disabled {
                    Text("connection broken").font(.caption2).foregroundStyle(.red)
                } else if stuck, let created = auth.created {
                    Text("no accounts \(AppState.relative(created).replacingOccurrences(of: " ago", with: "")) after connect — try Reconnect")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if let created = auth.created {
                    Text("first sync running… connected \(AppState.relative(created))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("first sync running…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if disabled || stuck {
                Button("Reconnect") { Task { await state.reconnect(auth) } }
                    .font(.caption)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.mini)
            }
            Button {
                removalTarget = RemovalTarget(id: auth.id, name: auth.displayName)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove this connection")
        }
        .padding(.vertical, 3)
    }

    // Picker + donut + one legend row per slice; explicit so the window can size itself.
    private var allocationHeight: CGFloat {
        let sliceCount = state.allocation(
            by: .init(rawValue: UserDefaults.standard.string(forKey: "snapbar.allocation.dim") ?? "") ?? .asset
        ).count
        guard sliceCount > 0 else { return 200 }
        return 24 + 155 + CGFloat(sliceCount) * 21 + 44
    }

    private var activityHeight: CGFloat {
        guard !state.activities.isEmpty else { return 170 }
        // Filter picker + one day-header per ~4 rows + row heights, capped and scrollable beyond.
        let rows = CGFloat(state.activities.count)
        return min(rows * 36 + (rows / 4 + 1) * 24 + 48, 380)
    }

    private var listHeight: CGFloat {
        let accountCount = state.groups.reduce(0) { $0 + $1.accounts.count }
        let attentionCount = state.attentionConnections.count
        guard accountCount + attentionCount > 0 else { return 170 }
        var height = CGFloat(state.groups.count) * 26 + CGFloat(accountCount) * 38
            + CGFloat(attentionCount) * 40 + 20
        for group in state.groups {
            for account in group.accounts where expanded.contains(account.id) {
                let detail = state.details[account.id]
                let rows = (detail?.positions.count ?? 0) + (detail?.cashByCurrency.count ?? 0)
                height += CGFloat(max(rows, 1)) * 30 + 8
            }
        }
        return min(max(height, 60), 380)
    }

    private func groupView(_ group: InstitutionGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.moneyCompact(group.totalInBase, state.config.baseCurrency))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, 6)
            ForEach(group.accounts) { account in
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: STAccount) -> some View {
        let isExpanded = expanded.contains(account.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded { expanded.remove(account.id) } else { expanded.insert(account.id) }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(account.displayName).font(.callout).lineLimit(1)
                        if let sync = account.lastSync {
                            let stale = Date().timeIntervalSince(sync) > 36 * 3600
                            Text("synced \(AppState.relative(sync))\(stale ? " ⚠︎" : "")")
                                .font(.caption2)
                                .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        }
                    }
                    Spacer()
                    Text(state.money(account.amount, account.currency))
                        .font(.callout)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
            .contextMenu {
                if let authId = account.brokerageAuthorization {
                    Button(role: .destructive) {
                        removalTarget = RemovalTarget(
                            id: authId,
                            name: "\(account.institutionName ?? account.displayName) connection"
                        )
                    } label: {
                        Label("Remove Connection…", systemImage: "trash")
                    }
                }
            }

            if isExpanded {
                breakdownView(account)
            }
        }
    }

    // Expanded per-account breakdown: cash rows + positions by value.
    @ViewBuilder
    private func breakdownView(_ account: STAccount) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let detail = state.details[account.id] {
                if let error = detail.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                } else if detail.positions.isEmpty && detail.cashByCurrency.isEmpty {
                    Text("No holdings")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 2)
                } else {
                    ForEach(detail.cashByCurrency, id: \.code) { cash in
                        holdingRow(
                            ticker: "Cash",
                            subtitle: cash.code,
                            value: cash.amount,
                            currency: cash.code,
                            metrics: []
                        )
                    }
                    ForEach(detail.positions) { position in
                        holdingRow(
                            ticker: position.ticker,
                            subtitle: positionSubtitle(position),
                            value: position.value,
                            currency: position.currencyCode,
                            metrics: positionMetrics(position)
                        )
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading holdings…").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 4)
    }

    // Percent-based, so they stay meaningful in privacy mode.
    private func positionMetrics(_ position: STPosition) -> [(text: String, color: Color)] {
        var metrics: [(String, Color)] = []
        if let day = state.dayChangePct(position) {
            metrics.append((String(format: "%@%.2f%% td", day >= 0 ? "▲" : "▼", abs(day)), day >= 0 ? .green : .red))
        }
        if let pnl = state.pnlPct(position) {
            metrics.append((String(format: "%+.1f%%", pnl), pnl >= 0 ? .green : .red))
        }
        return metrics
    }

    private func holdingRow(
        ticker: String, subtitle: String?, value: Double, currency: String,
        metrics: [(text: String, color: Color)]
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(ticker).font(.caption.weight(.medium)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(state.money(value, currency))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !metrics.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(metrics.indices, id: \.self) { i in
                            Text(metrics[i].text)
                                .font(.system(size: 9))
                                .monospacedDigit()
                                .foregroundStyle(metrics[i].color)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func positionSubtitle(_ position: STPosition) -> String {
        // Quantities reveal holding sizes — omit them in privacy mode (price is public data).
        if state.privacyMode {
            if let price = position.price {
                return AppState.fullCurrency(price, code: position.currencyCode)
            }
            return position.name ?? ""
        }
        var parts: [String] = []
        let qty = position.quantity
        if qty != 0 {
            let qtyStr = qty == qty.rounded() && abs(qty) < 1_000_000
                ? String(format: "%.0f", qty)
                : String(format: "%.4f", qty)
            if let price = position.price {
                parts.append("\(qtyStr) × \(AppState.fullCurrency(price, code: position.currencyCode))")
            } else {
                parts.append("\(qtyStr) units")
            }
        }
        if parts.isEmpty, let name = position.name { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await state.connectAccount() }
            } label: {
                Label("Connect Account", systemImage: "plus.circle")
            }
            Button {
                Task { await state.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(state.isRefreshing)
            Spacer()
            Menu {
                Button(state.privacyMode ? "Show Amounts" : "Hide Amounts") { state.privacyMode.toggle() }
                Divider()
                if state.config.mode == .personal {
                    Button("Sign Out of SnapTrade") { state.signOutPersonal() }
                } else {
                    Button("Edit API Keys…") { state.showSetup = true }
                    if !state.secretsInKeychain {
                        Button("Move Keys to Keychain") { state.moveKeysToKeychain() }
                    }
                }
                Button("Open Config") { state.openConfig() }
                Button("Reload Config") { state.reloadConfig() }
                if Notifier.shared.available {
                    Button("Test Notification") {
                        Notifier.shared.post(
                            id: "test-\(Int(Date().timeIntervalSince1970))",
                            title: "SnapBar notifications work",
                            body: "You'll get one when a dividend, trade, or deposit lands."
                        )
                    }
                }
                Divider()
                quitButton
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .padding(10)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var quitButton: some View {
        Button("Quit SnapBar") { NSApplication.shared.terminate(nil) }
    }
}
