import SwiftUI
import AppKit

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Literal brand hex values from `ui/prototype.html`'s dark+light comps — this unit
/// (`3-liquid-glass`) is where they land, per the forward-reference in `StatusIcon.swift`/
/// `SecurityIndicators.swift`. No `.xcassets` in this SPM package, so light/dark adapts via
/// `NSColor`'s dynamic-provider init instead of an asset-catalog color set.
public extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Mounted read/write. `#34c759` light / `#30d158` dark.
    static let ntfsGreen = Color(light: NSColor(hex: 0x34C759), dark: NSColor(hex: 0x30D158))
    /// Mounting / interactive accent. `#007aff` light / `#2d9cff` dark.
    static let ntfsBlue = Color(light: NSColor(hex: 0x007AFF), dark: NSColor(hex: 0x2D9CFF))
    /// Read-only / dirty-journal warning. `#ffd60a`, same both appearances in the comp.
    static let ntfsYellow = Color(NSColor(hex: 0xFFD60A))
    /// Error. `#ff453a`, same both appearances in the comp.
    static let ntfsRed = Color(NSColor(hex: 0xFF453A))
    /// Idle menu-bar glyph only. Light mode keeps the system-adaptive secondary-label gray
    /// (already legible against the light menu bar); dark mode goes pure white instead of
    /// `.secondary`'s dark-mode gray, which reads too close to a dark desktop background behind
    /// a translucent dark menu bar to be easily seen. Deliberately idle-only — the other states
    /// (`ntfsBlue`/`ntfsGreen`/`ntfsYellow`/`ntfsRed` above) are already saturated brand colors
    /// with plenty of contrast in both appearances and must not change.
    static let ntfsIdleGray = Color(light: NSColor.secondaryLabelColor, dark: .white)
}
