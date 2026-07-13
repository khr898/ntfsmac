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
        NSLog("ntfsmac: openPathInFinder starting multi-tier open for path: '%@'", path)
        let url = URL(fileURLWithPath: path)
        
        // Tier 1: Native URL opening (cleanest, standard Cocoa way)
        if NSWorkspace.shared.open(url) {
            NSLog("ntfsmac: Tier 1 succeeded (NSWorkspace.shared.open)")
            return true
        }
        
        // Tier 2: selectFile (AppKit fallback, reveals directory content)
        if NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) {
            NSLog("ntfsmac: Tier 2 succeeded (NSWorkspace.shared.selectFile)")
            return true
        }
        
        // Tier 3: activateFileViewerSelecting (opens parent folder and highlights this drive)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        NSLog("ntfsmac: Tier 3 executed (NSWorkspace.shared.activateFileViewerSelecting)")
        
        // Tier 4: Spawning /usr/bin/open directly via Process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                NSLog("ntfsmac: Tier 4 succeeded (/usr/bin/open Process)")
                return true
            }
        } catch {
            NSLog("ntfsmac: Tier 4 failed with error: \(error)")
        }
        
        // Tier 5: Spawning /bin/sh shell to open path (mimics terminal exactly)
        let shProcess = Process()
        shProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        shProcess.arguments = ["-c", "open \"$1\"", "sh", path]
        do {
            try shProcess.run()
            shProcess.waitUntilExit()
            if shProcess.terminationStatus == 0 {
                NSLog("ntfsmac: Tier 5 succeeded (/bin/sh Process)")
                return true
            }
        } catch {
            NSLog("ntfsmac: Tier 5 failed with error: \(error)")
        }
        
        NSLog("ntfsmac: All 5 open tiers failed")
        return false
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
        NSLog("ntfsmac: FinderOpener.open called for drive: \(drive.identifier) (label: '\(drive.label)'), state: \(state), mountPoint arg: '\(mountPoint ?? "nil")'")
        guard isEnabled(for: state) else {
            NSLog("ntfsmac: FinderOpener.open not enabled for state \(state)")
            return
        }
        
        var path = mountPoint
        
        if path == nil || path?.isEmpty == true {
            NSLog("ntfsmac: mountPoint is nil/empty, querying anylinuxfs status...")
            let result = runner.run(anylinuxfsPath, ["status"])
            NSLog("ntfsmac: anylinuxfs status returned exitCode \(result.exitCode)")
            if result.exitCode == 0 {
                let lines = result.output.components(separatedBy: .newlines)
                let searchPrefix = "/dev/\(drive.identifier) on "
                if let statusLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(searchPrefix) }) {
                    NSLog("ntfsmac: found matching status line: '\(statusLine)'")
                    if let onRange = statusLine.range(of: " on "),
                       let parenRange = statusLine.range(of: " (", options: [], range: onRange.upperBound..<statusLine.endIndex) {
                        path = String(statusLine[onRange.upperBound..<parenRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        NSLog("ntfsmac: parsed path from status: '\(path ?? "nil")'")
                    }
                } else {
                    NSLog("ntfsmac: no status line matching prefix '\(searchPrefix)'")
                }
            } else {
                NSLog("ntfsmac: anylinuxfs status failed with output: '\(result.output)'")
            }
        }
        
        let finalPath = path ?? Self.mountPoint(for: drive)
        NSLog("ntfsmac: finalPath resolved to: '\(finalPath)'")
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
