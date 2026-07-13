import AppKit
import SwiftUI

// ponytail: MenuBarExtra's label doesn't rasterize into the real NSStatusItem for
// Image(systemName:) directly (confirmed live: icon vanishes entirely) — same class of bug
// commit e762f6d fixed for the old Canvas glyph. Pre-rendering to NSImage via ImageRenderer
// is the proven fix; reapplying it here for the new SF-Symbol glyph.

public struct StatusIconStyle: Equatable {
    public let color: Color
    public let isIdle: Bool
    public let isPulsing: Bool
}

/// GUI-PLAN.md "Menu-bar icon states" table, exact mapping:
/// grey=idle, blue(pulsing)=mounting, green=rw, yellow=ro-dirty, red=error.
/// Literal hex values from `ui/prototype.html` (`Colors.swift`) — idle uses `.ntfsIdleGray`
/// (system secondary-label gray in light mode, pure white in dark mode) rather than a custom
/// brand hex: the comp only draws translucent white/black there, and `.secondary`'s own
/// dark-mode gray reads too faintly against a dark desktop background. Every other state below
/// keeps its exact saturated brand color unchanged in both appearances.
public enum StatusIcon {
    public static func style(for state: MountState) -> StatusIconStyle {
        switch state {
        case .idle:
            return StatusIconStyle(color: .ntfsIdleGray, isIdle: true, isPulsing: false)
        case .mounting:
            return StatusIconStyle(color: .ntfsBlue, isIdle: false, isPulsing: true)
        case .mountedReadWrite:
            return StatusIconStyle(color: .ntfsGreen, isIdle: false, isPulsing: false)
        case .mountedReadOnly:
            // Deliberate, healthy read-only — same green as a successful read-write mount
            // (this is a config choice, not a warning); GUI-PLAN.md's icon table predates
            // this case and only documents the dirty-journal yellow, not this one.
            return StatusIconStyle(color: .ntfsGreen, isIdle: false, isPulsing: false)
        case .mountedReadOnlyDirty:
            return StatusIconStyle(color: .ntfsYellow, isIdle: false, isPulsing: false)
        case .error:
            return StatusIconStyle(color: .ntfsRed, isIdle: false, isPulsing: false)
        }
    }
}

/// Menu-bar label view. Uses the same SF Symbol (`externaldrive.fill`) as the rest of the app's
/// drive icons (`DriveHeaderGlyph`/`DriveRowGlyph`, `gui/Style/Icons.swift`) — explicit product
/// decision to match the app's standard icon rather than keep a one-off custom glyph here.
/// `Image(systemName:)` is one of the two content types `MenuBarExtra`'s label reliably
/// rasterizes into the real `NSStatusItem` button (confirmed empirically earlier: a bare `Text`
/// or `Image` renders, a bare `Rectangle`/custom `Canvas` does not) — no `ImageRenderer`
/// pre-rendering workaround needed here, unlike the literal comp-transcribed glyphs elsewhere.
/// Pulsing is a plain opacity animation, not `.symbolEffect` (SF Symbols 5, macOS 14+/
/// Sonoma-only) — this project's floor is macOS 13.0.
public struct StatusIconView: View {
    let state: MountState
    @State private var isDim = false

    public init(state: MountState) {
        self.state = state
    }

    public var body: some View {
        let style = StatusIcon.style(for: state)
        Image(nsImage: Self.renderedGlyph(color: style.color))
            .opacity(style.isPulsing && isDim ? 0.4 : 1.0)
            .onAppear {
                guard style.isPulsing else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }

    private static func renderedGlyph(color: Color) -> NSImage {
        let renderer = ImageRenderer(content:
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 15, height: 12))
    }
}
