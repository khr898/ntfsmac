import SwiftUI

/// GUI-PLAN.md "Menu-bar icon states" — the five states the icon/popover ever render.
/// Styling (exact colors) lives in `StatusIcon.swift`; `3-liquid-glass` refines hex values later.
public enum MountState: Equatable, Sendable {
    case idle
    case mounting
    case mountedReadWrite
    /// Mounted read-only *by request* (`Settings.defaultMountMode == .readOnly`) — distinct
    /// from `.mountedReadOnlyDirty`: this is intentional and healthy, not a warning, so it
    /// must never trigger `DirtyBannerView`'s "unclean journal"/"mount read/write anyway"
    /// flow. Added when `MountController.mount(readOnly:)` was wired to a real NFS
    /// client-side `ro` mount option — `.mountedReadWrite` was being reported even for a
    /// successful read-only-by-request mount before this case existed (a real bug, caught
    /// by review before it shipped).
    case mountedReadOnly
    case mountedReadOnlyDirty
    case error
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var state: MountState = .idle

    public init() {}
}
