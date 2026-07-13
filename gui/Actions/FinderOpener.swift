import AppKit
import HelperShared

/// Seam over `NSWorkspace` so tests don't drive a real Finder window (same retroactive-
/// conformance-in-a-new-file pattern as `HelperClient: HelperMounting`).
public protocol WorkspaceOpening {
    func activateFileViewerSelecting(_ fileURLs: [URL])
    @discardableResult
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: WorkspaceOpening {}

/// `Open in Finder` (GUI-PLAN.md "Popover — mounted"): reveals the mount point via
/// `NSWorkspace` — never a shell-out (this unit's Don't clause, e.g. no `open` subprocess).
@MainActor
public final class FinderOpener {
    private let workspace: any WorkspaceOpening

    public init(workspace: any WorkspaceOpening = NSWorkspace.shared) {
        self.workspace = workspace
    }

    /// GUI-PLAN.md "Popover — mounted" table: "Open in Finder | ... | Mounted". Read-only-dirty
    /// still counts as mounted (the volume is browsable even if writes are blocked).
    public func isEnabled(for state: MountState) -> Bool {
        state == .mountedReadWrite || state == .mountedReadOnly || state == .mountedReadOnlyDirty
    }

    /// `mountPoint`: the real, actually-requested path when the caller has one
    /// (`MountController.mountedMountPoint`, real as of the `Settings.defaultMountPoint` wiring)
    /// — falls back to the `/Volumes/<label>` heuristic guess below only when `nil` (the user
    /// never customized the default, so anylinuxfs picked its own path under `/Volumes/`).
    public func open(_ drive: Drive, state: MountState, mountPoint: String? = nil) {
        guard isEnabled(for: state) else { return }
        let path = mountPoint ?? Self.mountPoint(for: drive)
        workspace.open(URL(fileURLWithPath: path))
    }

    /// Fallback heuristic for when no real mount point is available (see
    /// `open(_:state:mountPoint:)` above) — GUI-PLAN.md "Preferences" table's documented default
    /// mount point convention (`/Volumes/<label>`).
    static func mountPoint(for drive: Drive) -> String {
        let name = drive.label.isEmpty ? drive.identifier : drive.label
        return "/Volumes/\(name)"
    }
}
