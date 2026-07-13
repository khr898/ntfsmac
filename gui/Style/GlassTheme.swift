import SwiftUI
import AppKit

/// `ui/prototype.html`'s literal vibrancy/blur recipe (macOS Tahoe "Liquid Glass" comp), translated
/// to `NSVisualEffectView` rather than the real `.glassEffect()` SwiftUI API — that API is
/// macOS 26+ only and would silently force L7's macOS 13.0+ floor up (HARD-STOP territory, same
/// reasoning `3-menubar-shell` already applied to `.symbolEffect(.pulse)`). `NSVisualEffectView`
/// gets the closest available system-material approximation while staying 13.0-compatible; the
/// comp's literal blur-radius/saturation/brightness CSS values aren't independently controllable
/// through this API, only `.material`/`.blendingMode` are — documented here, not silently dropped.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Popover background — `ui/prototype.html`'s dark+light "POPOVER" comps. Every state row
/// (mounted/idle/dirty/error) shares this same container recipe; only per-state accent colors
/// differ, handled elsewhere (`Colors.swift` + each state's own view). Literal: 13pt corner
/// radius, 14% white(dark)/11% black(light) border, subtle tint gradient. The comp layers two
/// box-shadows plus an inset rim-light per mode (`ui/prototype.html:107,288`) — SwiftUI's
/// `.shadow()` only supports one outer shadow, so this collapses to a single approximation
/// (dark: outer 0-22-56 layer only; light: outer 0-18-50 layer only), not full parity.
struct PopoverGlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffectView(material: .popover)
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.055), Color.white.opacity(0.02)]
                            : [Color.white.opacity(0.72), Color.white.opacity(0.58)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.11))
                )
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.6 : 0.22),
                    radius: colorScheme == .dark ? 28 : 25, y: colorScheme == .dark ? 22 : 18
                )
            )
    }
}

/// Preferences window content background — the comp's "Prefs content" recipe
/// (`rgba(18,18,24,0.72)` over a blurred base, dark only shown). The window titlebar (traffic
/// lights, its own blur) is real native `NSWindow` chrome in the actual app — the comp fakes it
/// in static HTML because it's a mockup; nothing to translate there, faking it here would
/// duplicate what AppKit already draws for free.
struct WindowGlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            ZStack {
                VisualEffectView(material: .windowBackground)
                if colorScheme == .dark {
                    Color(red: 18.0 / 255, green: 18.0 / 255, blue: 24.0 / 255).opacity(0.72)
                }
            }
        )
    }
}

/// Preferences row card — `ui/prototype.html`'s "Row:" comps: `rgba(255,255,255,0.05)` fill,
/// `rgba(255,255,255,0.08)` border, 10pt radius (dark only shown in the comp; light follows the
/// same white-alpha→black-alpha substitution the mounted-state dark/light pair already
/// establishes throughout the rest of the comp, not a new invented value).
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))
            )
    }
}

public extension View {
    /// Menu-bar popover container glass — apply once at the popover content root.
    func popoverGlassBackground() -> some View { modifier(PopoverGlassBackground()) }
    /// Preferences window content glass — apply once at the window's root view.
    func windowGlassBackground() -> some View { modifier(WindowGlassBackground()) }
    /// One Preferences row's card chrome.
    func glassCard() -> some View { modifier(GlassCard()) }
}
