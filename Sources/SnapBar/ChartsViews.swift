import Charts
import SwiftUI

// Cohesive dashboard palette; slate is reserved for Other/Unclassified.
private let palette: [Color] = [
    Color(red: 0.38, green: 0.55, blue: 0.98),  // cornflower
    Color(red: 0.29, green: 0.79, blue: 0.68),  // teal
    Color(red: 0.98, green: 0.72, blue: 0.32),  // amber
    Color(red: 0.94, green: 0.44, blue: 0.53),  // rose
    Color(red: 0.66, green: 0.53, blue: 0.96),  // violet
    Color(red: 0.36, green: 0.77, blue: 0.97),  // sky
    Color(red: 0.67, green: 0.85, blue: 0.46),  // lime
    Color(red: 0.95, green: 0.56, blue: 0.36),  // coral
]
private let slate = Color(red: 0.56, green: 0.61, blue: 0.69)

// MARK: - Allocation donut

struct AllocationView: View {
    @ObservedObject var state: AppState
    @AppStorage("snapbar.allocation.dim") private var dimensionRaw = AppState.AllocationDimension.asset.rawValue
    @State private var hovered: String?

    private var dimension: AppState.AllocationDimension {
        AppState.AllocationDimension(rawValue: dimensionRaw) ?? .asset
    }

    var body: some View {
        let slices = state.allocation(by: dimension)
        let total = slices.reduce(0.0) { $0 + $1.value }

        return VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $dimensionRaw) {
                ForEach(AppState.AllocationDimension.allCases) { dim in
                    Text(dim.rawValue).tag(dim.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if slices.isEmpty {
                emptyState
            } else {
                donut(slices, total: total)
                legend(slices, total: total)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.pie")
                .font(.system(size: 26))
                .foregroundStyle(.quaternary)
            Text("No holdings data yet")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func donut(_ slices: [AppState.AllocationSlice], total: Double) -> some View {
        ZStack {
            Chart(slices) { slice in
                SectorMark(
                    angle: .value("Value", slice.value),
                    innerRadius: .ratio(0.64),
                    angularInset: 1.6
                )
                .cornerRadius(3)
                .foregroundStyle(color(for: slice, in: slices))
                .opacity(hovered == nil || hovered == slice.name ? 1 : 0.3)
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                hovered = sliceAt(location, proxy: proxy, geo: geo, slices: slices, total: total)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            centerLabel(slices, total: total)
        }
        .frame(height: 155)
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder
    private func centerLabel(_ slices: [AppState.AllocationSlice], total: Double) -> some View {
        if let hovered, let slice = slices.first(where: { $0.name == hovered }) {
            VStack(spacing: 1) {
                Text(slice.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 78)
                Text(state.moneyCompact(slice.value, state.config.baseCurrency))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(total > 0 ? String(format: "%.1f%%", slice.value / total * 100) : "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            VStack(spacing: 1) {
                Text(state.moneyCompact(total, state.config.baseCurrency))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(dimension.rawValue.lowercased() + " mix")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // Map a pointer position to the slice under it: distance must be on the ring,
    // then the clockwise-from-top angle picks the slice by cumulative fraction.
    private func sliceAt(
        _ location: CGPoint, proxy: ChartProxy, geo: GeometryProxy,
        slices: [AppState.AllocationSlice], total: Double
    ) -> String? {
        guard total > 0 else { return nil }
        let frame = geo[proxy.plotAreaFrame]
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let outer = min(frame.width, frame.height) / 2
        let inner = outer * 0.64
        guard distance >= inner * 0.85, distance <= outer * 1.06 else { return nil }

        var angle = atan2(dy, dx) + .pi / 2   // 0 at 12 o'clock, clockwise
        if angle < 0 { angle += 2 * .pi }
        let fraction = angle / (2 * .pi)
        var cumulative = 0.0
        for slice in slices {
            cumulative += slice.value / total
            if fraction <= cumulative { return slice.name }
        }
        return slices.last?.name
    }

    private func color(for slice: AppState.AllocationSlice, in slices: [AppState.AllocationSlice]) -> Color {
        if slice.name == "Other" || slice.name == "Unclassified" { return slate }
        let index = slices.firstIndex(where: { $0.id == slice.id }) ?? 0
        return palette[index % palette.count]
    }

    private func legend(_ slices: [AppState.AllocationSlice], total: Double) -> some View {
        VStack(spacing: 2) {
            ForEach(slices) { slice in
                let isHovered = hovered == slice.name
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: slice, in: slices))
                        .frame(width: 8, height: 8)
                    Text(slice.name)
                        .font(.caption.weight(isHovered ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(state.moneyCompact(slice.value, state.config.baseCurrency))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Text(total > 0 ? String(format: "%4.1f%%", slice.value / total * 100) : "–")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 42, alignment: .trailing)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? color(for: slice, in: slices).opacity(0.16) : .clear)
                )
                // Bidirectional: hovering the row highlights its slice too.
                .onHover { inside in
                    if inside {
                        hovered = slice.name
                    } else if hovered == slice.name {
                        hovered = nil
                    }
                }
            }
        }
    }
}

// MARK: - Net worth trend

struct TrendView: View {
    @ObservedObject var state: AppState
    @AppStorage("snapbar.trend.range") private var rangeIndex = 3

    private static let ranges: [(label: String, seconds: TimeInterval?)] = [
        ("1H", 3600), ("1D", 86_400), ("1W", 604_800), ("All", nil),
    ]

    var body: some View {
        let all = state.history.filter { $0.c == state.config.baseCurrency }
        let range = Self.ranges[min(max(rangeIndex, 0), Self.ranges.count - 1)]
        let points = range.seconds.map { cutoff in
            all.filter { $0.date >= Date().addingTimeInterval(-cutoff) }
        } ?? all

        return VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $rangeIndex) {
                ForEach(0..<Self.ranges.count, id: \.self) { i in
                    Text(Self.ranges[i].label).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if points.count < 2 {
                emptyState(hasAnyHistory: all.count >= 2)
            } else {
                let flows = state.flowEvents(since: points.first!.date)
                header(points, flows: flows)
                chart(points, flows: flows)
                if !flows.isEmpty {
                    Text("solid = net worth · dashed = excl. deposits/withdrawals")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // Cumulative external flows at each history point, for the deposit-adjusted series.
    private func adjustedSeries(_ points: [HistoryPoint], flows: [(date: Date, amount: Double)]) -> [HistoryPoint] {
        var cumulative = 0.0
        var flowIndex = 0
        return points.map { point in
            while flowIndex < flows.count && flows[flowIndex].date <= point.date {
                cumulative += flows[flowIndex].amount
                flowIndex += 1
            }
            return HistoryPoint(t: point.t, v: point.v - cumulative, c: point.c)
        }
    }

    private func emptyState(hasAnyHistory: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 26))
                .foregroundStyle(.quaternary)
            Text(hasAnyHistory ? "No data in this range yet" : "Collecting history…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(hasAnyHistory
                ? "Pick a wider range."
                : "A snapshot is recorded on every refresh, so the line builds from today onward.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func header(_ points: [HistoryPoint], flows: [(date: Date, amount: Double)]) -> some View {
        let first = points.first!.v
        let last = points.last!.v
        let delta = last - first
        let pct = first != 0 ? delta / abs(first) * 100 : 0
        let flat = abs(delta) < 0.01
        let up = delta >= 0
        let netFlow = flows.reduce(0.0) { $0 + $1.amount }
        let growth = delta - netFlow

        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                if flat {
                    Text("— flat")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(up ? "▲" : "▼") \(state.money(abs(delta), state.config.baseCurrency)) (\(String(format: "%.2f", abs(pct)))%)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(up ? .green : .red)
                }
                Spacer()
                Text("since \(points.first!.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if abs(netFlow) > 0.01 {
                let growthUp = growth >= 0
                Text("\(growthUp ? "▲" : "▼") \(state.money(abs(growth), state.config.baseCurrency)) excl. \(state.money(netFlow, state.config.baseCurrency)) net deposits")
                    .font(.caption2)
                    .foregroundStyle(growthUp ? AnyShapeStyle(Color.green.opacity(0.85)) : AnyShapeStyle(Color.red.opacity(0.85)))
            }
        }
    }

    private func chart(_ points: [HistoryPoint], flows: [(date: Date, amount: Double)]) -> some View {
        let adjusted = flows.isEmpty ? [] : adjustedSeries(points, flows: flows)
        let values = points.map(\.v) + adjusted.map(\.v)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.18, max(abs(hi) * 0.002, 1))
        let up = (points.last?.v ?? 0) >= (points.first?.v ?? 0)
        let tint: Color = up ? .green : .red

        return Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Net worth", point.v)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Net worth", point.v),
                    series: .value("Series", "value")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(adjusted) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Adjusted", point.v),
                    series: .value("Series", "adjusted")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(slate.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
            }
            if let last = points.last {
                PointMark(
                    x: .value("Time", last.date),
                    y: .value("Net worth", last.v)
                )
                .symbolSize(36)
                .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(state.privacyMode ? "•••" : AppState.compactCurrency(v, code: state.config.baseCurrency))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
