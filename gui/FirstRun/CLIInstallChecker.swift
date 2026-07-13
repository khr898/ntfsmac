import Foundation
import HelperShared

/// Detects whether the CLI + vendored binaries are actually staged at `installPrefix`
/// (`/usr/local/ntfsmac`) — distinct from `HelperInstaller`, which only blesses the privileged
/// XPC helper daemon and assumes the CLI tree already exists (`build/package-app.sh`'s own
/// comment: "Does NOT bundle vendor/bin/* ... CLI installed separately via install.sh/tap
/// before the GUI DMG is ever opened" — a deliberate architecture choice, not a gap this file
/// works around). Without this check, every action (`DriveScanner`, `DiagnoseRunner`,
/// `MountController`) silently ENOENTs against a missing binary with no clear cause surfaced —
/// this makes "CLI not installed" its own first-class, permanently-checked state instead of a
/// cryptic per-action failure.
@MainActor
public final class CLIInstallChecker: ObservableObject {
    @Published public private(set) var isInstalled = false

    private let candidatePaths: [String]
    private let fileManager: FileManager

    /// Checks every install location the CLI could actually be at (`installPrefix` — install.sh
    /// / manual — or `homebrewOptPrefix` — `brew install ntfsmac`, which Homebrew's own no-sudo
    /// policy keeps out of `installPrefix`) — same candidate list `HelperService` resolves
    /// against, so the GUI's "CLI not installed" gate agrees with what the privileged helper
    /// can actually reach.
    public init(candidatePaths: [String] = ntfsmacCandidatePrefixes.map { "\($0)/bin/ntfsmac" }, fileManager: FileManager = .default) {
        self.candidatePaths = candidatePaths
        self.fileManager = fileManager
    }

    public func check() {
        isInstalled = candidatePaths.contains { fileManager.isExecutableFile(atPath: $0) }
    }
}
