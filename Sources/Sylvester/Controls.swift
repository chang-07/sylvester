import SwiftUI

// Fixed control heights. The popover can't size itself to a ScrollView (its ideal height
// is ~0), so MenuView computes tab heights by hand — those sums need a constant here
// rather than a magic number that silently goes stale when a control changes.
enum ControlMetrics {
    static let pillRow: CGFloat = 20
}

// Equal-width segmented control.
//
// SwiftUI's .segmented Picker sizes each segment to its own label, so
// "Accounts | Allocation | Trend | Activity" came out visibly lopsided and stopped short
// of the popover width. NSSegmentedControl has segmentDistribution = .fillEqually for
// exactly this, but SwiftUI doesn't surface it — so draw it.
struct SegmentedBar<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let title: String
        // Shows the unread marker on the Activity tab without widening the segment.
        var dot: Bool = false

        init(_ value: Value, _ title: String, dot: Bool = false) {
            self.value = value
            self.title = title
            self.dot = dot
        }
    }

    let segments: [Segment]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments.count, id: \.self) { index in
                let segment = segments[index]
                let selected = selection == segment.value
                Button {
                    selection = segment.value
                } label: {
                    HStack(spacing: 3) {
                        Text(segment.title)
                        if segment.dot {
                            Circle()
                                .fill(selected ? Color.white : Color.accentColor)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .font(Theme.label.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                    .lineLimit(1)
                    // The whole point: every segment claims the same share of the row.
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.13)))
    }
}

// Sub-filter pills. Lighter than a second full-width segmented control stacked under the
// tab bar — that read as two peers competing rather than a filter belonging to the list
// below it. Sized to content and left-aligned, so it can't be mistaken for the tab bar.
struct PillRow<Value: Hashable>: View {
    struct Pill {
        let value: Value
        let title: String

        init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    let pills: [Pill]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<pills.count, id: \.self) { index in
                let pill = pills[index]
                let selected = selection == pill.value
                Button {
                    selection = pill.value
                } label: {
                    Text(pill.title)
                        .font(Theme.micro.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .frame(height: ControlMetrics.pillRow)
                        .background(
                            Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.13))
                        )
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}
