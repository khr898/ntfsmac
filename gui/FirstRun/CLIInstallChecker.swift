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
    private let anylinuxfsPaths: [String]
    private let fileManager: FileManager

    /// Checks every install location the CLI could actually be at (`installPrefix` — install.sh
    /// / manual — or `homebrewOptPrefix` — `brew install ntfsmac`, which Homebrew's own no-sudo
    /// policy keeps out of `installPrefix`) — same candidate list `HelperService` resolves
    /// against, so the GUI's "CLI not installed" gate agrees with what the privileged helper
    /// can actually reach.
    ///
    /// `anylinuxfsPaths`: the dispatcher script (`ntfsmac`) alone is not sufficient — mount
    /// needs the `anylinuxfs` binary to actually do anything. Without this check the UI showed
    /// the Mount button even when `anylinuxfs` was missing (e.g. `stageCLI` partially failed or
    /// `removeDependencies` deleted the prefix), producing a cryptic "command not found" shell
    /// error instead of `CLIMissingView`'s Retry button.
    public init(
        candidatePaths: [String] = ntfsmacCandidatePrefixes.map { "\($0)/bin/ntfsmac" },
        anylinuxfsPaths: [String] = ntfsmacCandidatePrefixes.map { "\($0)/bin/anylinuxfs" },
        fileManager: FileManager = .default
    ) {
        self.candidatePaths = candidatePaths
        self.anylinuxfsPaths = anylinuxfsPaths
        self.fileManager = fileManager
    }

    public func check() {
        let hasDispatcher = candidatePaths.contains { fileManager.isExecutableFile(atPath: $0) }
        let hasAnylinuxfs = anylinuxfsPaths.contains { fileManager.isExecutableFile(atPath: $0) }
        isInstalled = hasDispatcher && hasAnylinuxfs
    }
}
