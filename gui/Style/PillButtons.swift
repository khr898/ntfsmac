import SwiftUI

/// `ui/prototype.html`'s recurring pill-button recipes (rounded rect fill + border + label),
/// e.g. comp lines 153/157/231/234/238 — same shape family, different fill/border/foreground
/// per semantic role (neutral, destructive/unmount, install/primary, warning). One
/// `ButtonStyle` parameterized by those three colors instead of one struct per role, since the
/// only thing that varies between call sites is the color triple and corner radius.
public struct GlassPillButtonStyle: ButtonStyle {
    public var fill: Color
    public var border: Color
    public var foreground: Color
    public var cornerRadius: CGFloat = 8
    public var horizontalPadding: CGFloat = 8
    public var verticalPadding: CGFloat = 7
    public var fontSize: CGFloat = 12
    public var fontWeight: Font.Weight = .medium

    public init(
        fill: Color, border: Color, foreground: Color,
        cornerRadius: CGFloat = 8, horizontalPadding: CGFloat = 8, verticalPadding: CGFloat = 7,
        fontSize: CGFloat = 12, fontWeight: Font.Weight = .medium
    ) {
        self.fill = fill
        self.border = border
        self.foreground = foreground
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.fontSize = fontSize
        self.fontWeight = fontWeight
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

public extension ButtonStyle where Self == GlassPillButtonStyle {
    /// Neutral pill — "Open in Finder", empty-state "Refresh".
    /// Comp: `rgba(255,255,255,0.08)` fill / `0.11` border dark, `rgba(0,0,0,0.05)`/`0.09` light.
    static func glassNeutral(colorScheme: ColorScheme) -> GlassPillButtonStyle {
        colorScheme == .dark
            ? GlassPillButtonStyle(fill: Color.white.opacity(0.08), border: Color.white.opacity(0.11), foreground: Color.white.opacity(0.72))
            : GlassPillButtonStyle(fill: Color.black.opacity(0.05), border: Color.black.opacity(0.09), foreground: Color.black.opacity(0.6))
    }

    /// Footer pill — "Diagnose"/"Quit". Comp: `0.07`/`0.09` dark, `0.05`/`0.08` light.
    static func glassFooter(colorScheme: ColorScheme, foregroundOpacity: Double = 0.58) -> GlassPillButtonStyle {
        colorScheme == .dark
            ? GlassPillButtonStyle(fill: Color.white.opacity(0.07), border: Color.white.opacity(0.09), foreground: Color.white.opacity(foregroundOpacity), cornerRadius: 7, verticalPadding: 0)
            : GlassPillButtonStyle(fill: Color.black.opacity(0.05), border: Color.black.opacity(0.08), foreground: Color.black.opacity(foregroundOpacity), cornerRadius: 7, verticalPadding: 0)
    }

    /// Destructive pill — "Unmount". Comp: `rgba(255,80,80,0.1)` / `0.22` border dark
    /// (`0.08`/`0.2` light with a slightly different red for contrast against a light bg).
    static func glassDestructive(colorScheme: ColorScheme) -> GlassPillButtonStyle {
        colorScheme == .dark
            ? GlassPillButtonStyle(fill: Color(red: 1, green: 80.0 / 255, blue: 80.0 / 255).opacity(0.1), border: Color(red: 1, green: 80.0 / 255, blue: 80.0 / 255).opacity(0.22), foreground: Color(red: 1, green: 110.0 / 255, blue: 110.0 / 255).opacity(0.9), horizontalPadding: 11)
            : GlassPillButtonStyle(fill: Color.ntfsRed.opacity(0.08), border: Color.ntfsRed.opacity(0.2), foreground: Color(red: 200.0 / 255, green: 30.0 / 255, blue: 20.0 / 255).opacity(0.85), horizontalPadding: 11)
    }

    /// Warning pill — "Mount read/write anyway…". Comp: `rgba(255,214,10,0.1)` / `0.22` border.
    static func glassWarning() -> GlassPillButtonStyle {
        GlassPillButtonStyle(fill: Color.ntfsYellow.opacity(0.1), border: Color.ntfsYellow.opacity(0.22), foreground: Color.ntfsYellow.opacity(0.78))
    }

    /// Primary/install pill — "Install Helper…". Comp: `rgba(45,156,255,0.18)` fill / `0.3`
    /// border, full-width, semibold, slightly larger text (comp line 690).
    static func glassPrimary() -> GlassPillButtonStyle {
        GlassPillButtonStyle(fill: Color.ntfsBlue.opacity(0.18), border: Color.ntfsBlue.opacity(0.3), foreground: .ntfsBlue, verticalPadding: 8, fontSize: 12.5, fontWeight: .semibold)
    }
}

/// Square icon-only footer button — Settings gear (comp: 30x28, `rgba(255,255,255,0.07)`/`0.09`
/// border dark, `rgba(0,0,0,0.05)`/`0.08` light).
public struct GlassIconButtonStyle: ButtonStyle {
    public var fill: Color
    public var border: Color

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(border))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

public extension ButtonStyle where Self == GlassIconButtonStyle {
    static func glassIcon(colorScheme: ColorScheme) -> GlassIconButtonStyle {
        colorScheme == .dark
            ? GlassIconButtonStyle(fill: Color.white.opacity(0.07), border: Color.white.opacity(0.09))
            : GlassIconButtonStyle(fill: Color.black.opacity(0.05), border: Color.black.opacity(0.08))
    }
}
