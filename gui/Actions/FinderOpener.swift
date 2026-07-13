import AppKit
import HelperShared

/// Seam over `NSWorkspace` so tests don't drive a real Finder window (same retroactive-
/// conformance-in-a-new-file pattern as `HelperClient: HelperMounting`).
public protocol WorkspaceOpening {
    @discardableResult
    func openPathInFinder(_ path: String) -> Bool
}

extension NSWorkspace: WorkspaceOpening {
    public func openPathInFinder(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

/// `Open in Finder` (GUI-PLAN.md "Popover — mounted"): reveals the mount point by
/// spawning `/usr/bin/open` via `Process` — `NSWorkspace.open(URL)` silently fails on
/// NFS-mounted volumes (which ntfsmac's vmnet bridge mounts are classified as), so the
/// subprocess approach is deliberate, not an oversight.
@MainActor
public final class FinderOpener {
    private let workspace: any WorkspaceOpening
    private let runner: any PrivilegedCommandRunning
    private let anylinuxfsPath: String

    public init(
        workspace: any WorkspaceOpening = NSWorkspace.shared,
        runner: any PrivilegedCommandRunning = RealCommandRunner(),
        anylinuxfsPath: String = "\(installPrefix)/bin/anylinuxfs"
    ) {
        self.workspace = workspace
        self.runner = runner
        self.anylinuxfsPath = anylinuxfsPath
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
        
        var path = mountPoint
        
        if path == nil || path?.isEmpty == true {
            let result = runner.run(anylinuxfsPath, ["status"])
            if result.exitCode == 0 {
                let lines = result.output.components(separatedBy: .newlines)
                let searchPrefix = "/dev/\(drive.identifier) on "
                if let statusLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(searchPrefix) }) {
                    if let onRange = statusLine.range(of: " on "),
                       let parenRange = statusLine.range(of: " (", options: [], range: onRange.upperBound..<statusLine.endIndex) {
                        path = String(statusLine[onRange.upperBound..<parenRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        
        let finalPath = path ?? Self.mountPoint(for: drive)
        workspace.openPathInFinder(finalPath)
    }

    /// Fallback heuristic for when no real mount point is available (see
    /// `open(_:state:mountPoint:)` above) — GUI-PLAN.md "Preferences" table's documented default
    /// mount point convention (`/Volumes/<label>`).
    static func mountPoint(for drive: Drive) -> String {
        let name = drive.label.isEmpty ? drive.identifier : drive.label
        return "/Volumes/\(name)"
    }
}
