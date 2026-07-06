import SwiftUI

struct ActivityFeedView: View {
    @ObservedObject var state: AppState
    @AppStorage("snapbar.activity.filter") private var filter = 0

    private static let filters = ["All", "Trades", "Income", "Cash"]

    private struct DaySection: Identifiable {
        var id: Date { day }
        var day: Date
        var items: [STActivity]
    }

    // 1 trades, 2 income, 3 cash/fees; nil -> only under All.
    private static func category(_ type: String?) -> Int? {
        let t = (type ?? "").uppercased()
        switch t {
        case "BUY", "SELL":
            return 1
        case "DIVIDEND", "INTEREST", "REI", "DIVIDEND_REINVESTMENT":
            return 2
        case "CONTRIBUTION", "WITHDRAWAL", "TRANSFER", "FEE", "TAX":
            return 3
        default:
            return t.contains("OPTION") ? 1 : nil
        }
    }

    private var filtered: [STActivity] {
        filter == 0 ? state.activities : state.activities.filter { Self.category($0.type) == filter }
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: filtered) { activity in
            cal.startOfDay(for: activity.date ?? .distantPast)
        }
        return grouped
            .map { DaySection(day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $filter) {
                ForEach(0..<Self.filters.count, id: \.self) { i in
                    Text(Self.filters[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            sectionHeader(section.day)
                            ForEach(section.items) { activity in
                                row(activity)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
        .onAppear { state.markActivitiesViewed() }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.quaternary)
            Text(filter == 0
                ? "No activity in the last 30 days"
                : "No \(Self.filters[filter].lowercased()) activity in the last 30 days")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func sectionHeader(_ day: Date) -> some View {
        let cal = Calendar.current
        let label: String
        if cal.isDateInToday(day) {
            label = "Today"
        } else if cal.isDateInYesterday(day) {
            label = "Yesterday"
        } else if day == .distantPast {
            label = "Undated"
        } else {
            label = day.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated))
        }
        return Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 7)
    }

    private func row(_ activity: STActivity) -> some View {
        let style = Self.style(for: activity.type)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.icon)
                .font(.system(size: 13))
                .foregroundStyle(style.tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(Self.title(for: activity, privacy: state.privacyMode))
                        .font(.callout)
                        .lineLimit(1)
                    if state.isNewActivity(activity) {
                        Circle().fill(.blue).frame(width: 6, height: 6)
                            .help("New since last sync")
                    }
                }
                Text(Self.subtitle(for: activity))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let amount = activity.amount, amount != 0 {
                Text(state.money(amount, activity.currencyCode))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(style.amountTint)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Presentation helpers

    private static func qtyString(_ units: Double?) -> String? {
        guard let units, units != 0 else { return nil }
        let q = abs(units)
        return q == q.rounded() && q < 1_000_000 ? String(format: "%.0f", q) : String(format: "%.4f", q)
    }

    static func title(for activity: STActivity, privacy: Bool = false) -> String {
        let type = (activity.type ?? "").uppercased()
        let ticker = activity.ticker
        // Quantities and raw descriptions reveal position sizes / amounts.
        let qty = privacy ? nil : qtyString(activity.units)
        switch type {
        case "BUY":
            if let ticker { return "Bought \(qty.map { "\($0) " } ?? "")\(ticker)" }
        case "SELL":
            if let ticker { return "Sold \(qty.map { "\($0) " } ?? "")\(ticker)" }
        case "DIVIDEND":
            return "Dividend\(ticker.map { " · \($0)" } ?? "")"
        case "REI", "DIVIDEND_REINVESTMENT":
            return "Reinvested\(ticker.map { " · \($0)" } ?? "")"
        case "CONTRIBUTION":
            return "Contribution"
        case "WITHDRAWAL":
            return "Withdrawal"
        case "INTEREST":
            return "Interest"
        case "FEE":
            return "Fee"
        case "TRANSFER":
            return "Transfer\(ticker.map { " · \($0)" } ?? "")"
        default:
            break
        }
        if let description = activity.description, !description.isEmpty,
           !(privacy && description.contains(where: \.isNumber)) {
            return description.count > 42 ? String(description.prefix(40)) + "…" : description
        }
        return type.isEmpty ? "Activity" : type.capitalized
    }

    static func subtitle(for activity: STActivity) -> String {
        var parts: [String] = []
        if let account = activity.account {
            parts.append(account.name ?? account.institutionName ?? "Account")
        } else if let institution = activity.institution, !institution.isEmpty {
            parts.append(institution)
        }
        let type = (activity.type ?? "").uppercased()
        if ["BUY", "SELL"].contains(type), let price = activity.price, price > 0 {
            parts.append("@ \(AppState.fullCurrency(price, code: activity.currencyCode))")
        }
        return parts.joined(separator: " · ")
    }

    static func style(for type: String?) -> (icon: String, tint: Color, amountTint: Color) {
        switch (type ?? "").uppercased() {
        case "BUY":
            return ("arrow.down.circle.fill", .blue, .primary)
        case "SELL":
            return ("arrow.up.circle.fill", .teal, .green)
        case "DIVIDEND", "INTEREST":
            return ("dollarsign.circle.fill", .green, .green)
        case "REI", "DIVIDEND_REINVESTMENT":
            return ("arrow.triangle.2.circlepath.circle.fill", .green, .secondary)
        case "CONTRIBUTION":
            return ("plus.circle.fill", .green, .green)
        case "WITHDRAWAL":
            return ("minus.circle.fill", .orange, .orange)
        case "FEE", "TAX":
            return ("creditcard.circle.fill", .red, .red)
        case "TRANSFER":
            return ("arrow.left.arrow.right.circle.fill", .purple, .secondary)
        default:
            return ("circle.fill", .gray, .secondary)
        }
    }
}
