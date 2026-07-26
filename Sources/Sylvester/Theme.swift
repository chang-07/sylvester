import AppKit
import SwiftUI

// One place for color and type. The point is consolidation, not a re-skin: these are the
// app's existing colors, gathered so there's a single place to change them instead of
// three (hand-tuned RGB baked into the menubar image, a private chart palette, and raw
// system colors scattered through the views).
//
// Selection/accent deliberately follows the system accent color rather than a brand hue —
// segmented controls and pills should match whatever the user picked in System Settings.
enum Theme {

    // MARK: - Gain / loss
    //
    // Views use the plain system colors. The menubar can't: it renders to a flat bitmap
    // over a translucent bar that picks up the desktop wallpaper, so it needs a pair tuned
    // per appearance and resolved at bake time.

    static let gain = Color.green
    static let loss = Color.red

    static func bakedGain(dark: Bool) -> Color {
        dark ? Color(red: 0.20, green: 0.84, blue: 0.44) : Color(red: 0.13, green: 0.60, blue: 0.28)
    }

    static func bakedLoss(dark: Bool) -> Color {
        dark ? Color(red: 1.00, green: 0.32, blue: 0.27) : Color(red: 0.82, green: 0.18, blue: 0.14)
    }

    static let alert = Color.red

    // MARK: - Series
    //
    // Categorical palette for the allocation donut. Slate is reserved for
    // Other/Unclassified so a catch-all bucket never reads as a real category.

    static let series: [Color] = [
        Color(red: 0.38, green: 0.55, blue: 0.98),  // cornflower
        Color(red: 0.29, green: 0.79, blue: 0.68),  // teal
        Color(red: 0.98, green: 0.72, blue: 0.32),  // amber
        Color(red: 0.94, green: 0.44, blue: 0.53),  // rose
        Color(red: 0.66, green: 0.53, blue: 0.96),  // violet
        Color(red: 0.36, green: 0.77, blue: 0.97),  // sky
        Color(red: 0.67, green: 0.85, blue: 0.46),  // lime
        Color(red: 0.95, green: 0.56, blue: 0.36),  // coral
    ]

    static let muted = Color(red: 0.56, green: 0.61, blue: 0.69)

    // MARK: - Type
    //
    // A ramp instead of ad-hoc sizes (the views had .callout, .caption, .caption2 plus
    // literal 9/12/13/15/17/26 across five files). Rounded is reserved for figures, so
    // numbers read as a family and prose doesn't.

    static let hero = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let figure = Font.system(size: 17, weight: .semibold, design: .rounded)
    static let figureSmall = Font.system(size: 15, weight: .semibold, design: .rounded)
    static let rowTitle = Font.callout
    static let label = Font.caption
    static let micro = Font.caption2
    static let tick = Font.system(size: 9)
}
