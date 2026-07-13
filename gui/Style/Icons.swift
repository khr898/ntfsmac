import SwiftUI

/// Popover header icon-box glyph. Color alone already encodes idle/mounted/dirty/error state
/// (`StatusIcon.style(for:)`), so one symbol suffices rather than a per-state variant.
public struct DriveHeaderGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "externaldrive.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
    }
}

/// Drive-row icon-box glyph.
public struct DriveRowGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "externaldrive.fill")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(color)
    }
}

/// Empty-state icon; `.badge.questionmark` reads as "no drive detected yet" without new copy.
public struct DriveGlyphEmpty: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "externaldrive.badge.questionmark")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(color)
    }
}

// MARK: - Alert triangles (dirty-journal warning banner, error state)

/// Warning triangle used in the dirty-journal banner.
public struct WarningTriangleGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5))
            .foregroundStyle(color)
    }
}

/// Error-state triangle (header icon-box + section content icon).
public struct ErrorTriangleGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(color)
    }
}

// MARK: - Small badge checkmark (security indicators)

/// Checkmark used inside the 15x15 circular security-indicator badge.
public struct ShieldCheckGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(color)
    }
}

// MARK: - Button glyphs

/// "Open in Finder" button icon.
public struct FinderGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: 10))
    }
}

/// "Unmount" button icon.
public struct EjectGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "eject.fill")
            .font(.system(size: 10))
    }
}

/// "Mount read/write anyway…" button icon.
public struct MountAnywayGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "lock.open.fill")
            .font(.system(size: 10))
    }
}

/// "Install Helper…" button icon.
public struct InstallHelperGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "square.and.arrow.down.fill")
            .font(.system(size: 11))
    }
}

/// Footer settings-gear icon-button glyph.
public struct SettingsGearGlyph: View {
    public var color: Color

    public var body: some View {
        Image(systemName: "gearshape.fill")
            .font(.system(size: 12))
            .foregroundStyle(color)
    }
}

/// Footer/error "Diagnose" button icon.
public struct DiagnoseGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "stethoscope")
            .font(.system(size: 10.5))
    }
}

/// Empty-state "Refresh" button icon.
public struct RefreshGlyph: View {
    public init() {}

    public var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 10.5))
    }
}

/// Speed-bar read/write chevrons.
public struct SpeedDirectionGlyph: View {
    public var color: Color
    /// `true` = up chevron (Read), `false` = down chevron (Write).
    public var pointsUp: Bool

    public var body: some View {
        Image(systemName: pointsUp ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
    }
}
