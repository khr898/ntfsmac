import Foundation
import HelperShared
import NtfsmacGUI

/// Live-screen verification harness — lets every popover state (including states normally only
/// reachable with a real NTFS drive mounted) be exercised in the *actual* packaged app via each
/// type's existing test-DI seam, not just headless `ImageRenderer` tests. Inert by default: only
/// activates when `NTFSMAC_UI_DEMO` is set, which a real install never does. Kept in the tree
/// (not stripped before commit) so the next screen audit doesn't have to be re-derived from
/// scratch — see UITest.md.
///
/// `NTFSMAC_UI_DEMO=clean|dirty|error dist/ntfsmac.app/Contents/MacOS/ntfsmac-gui`
@MainActor
enum DemoScaffold {
    static func mountController(mode: String, appState: AppState) -> MountController {
        MountController(
            helper: DemoHelperMounting(shouldFail: mode == "error"),
            readOnlyChecker: DemoReadOnlyChecker(stillReadOnly: mode == "dirty"),
            appState: appState
        )
    }

    static func remountController(appState: AppState) -> RemountController {
        RemountController(
            helper: DemoHelperMounting(shouldFail: false),
            readOnlyChecker: DemoReadOnlyChecker(stillReadOnly: false),
            appState: appState
        )
    }

    static func driveScanner() -> DriveScanner {
        DriveScanner(runner: DemoCommandRunner())
    }

    static func throughputMonitor() -> ThroughputMonitor {
        ThroughputMonitor(counter: DemoByteCounter())
    }

    /// Separate from `NTFSMAC_UI_DEMO`: install-outcome and mount-state are orthogonal axes, and
    /// unlike mounting, `HelperInstaller`'s real path is a one-shot OS auth dialog — faking
    /// denied/failed here avoids clicking "Cancel" on a real `SMJobBless` prompt repeatedly during
    /// a screen audit. `NTFSMAC_INSTALL_DEMO=denied|failed` (a real accept must still go through
    /// `RealHelperInstallService` — this seam never fakes `.installed`).
    static func helperInstaller(outcome: String) -> HelperInstaller {
        let result: HelperInstallOutcome = outcome == "failed"
            ? .failed("demo: SMJobBless failed (fake)")
            : .denied("demo: Authorization was denied (fake)")
        return HelperInstaller(service: DemoHelperInstallService(outcome: result))
    }
}

private struct DemoHelperInstallService: HelperInstallService {
    let outcome: HelperInstallOutcome
    func isInstalled(label: String) -> Bool { false }
    func bless(label: String) -> HelperInstallOutcome { outcome }
}

private struct DemoCommandRunner: PrivilegedCommandRunning {
    func run(_ path: String, _ args: [String]) -> CommandResult {
        CommandResult(
            output: "   1:                  GUID_partition_scheme                        *1.0 TB     disk4\n   2:  Microsoft Basic Data      DEMO-DRIVE               500.0 GB   disk4s2\n",
            exitCode: 0
        )
    }
    func runPipingStdin(_ input: String, to path: String, _ args: [String]) -> CommandResult { CommandResult(output: "", exitCode: 0) }
}

private struct DemoHelperMounting: HelperMounting {
    let shouldFail: Bool
    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult {
        try? await Task.sleep(for: .seconds(1))
        if shouldFail { return CommandResult(output: "demo: mount failed (fake ntfs-3g exit)", exitCode: 1) }
        return CommandResult(output: "mounted", exitCode: 0)
    }
    func unmount(target: String) async throws -> CommandResult { CommandResult(output: "unmounted", exitCode: 0) }
}

private struct DemoReadOnlyChecker: MountReadOnlyChecking {
    let stillReadOnly: Bool
    func isAnyNfsMountReadOnly() async -> Bool { stillReadOnly }
}

private final class DemoByteCounter: InterfaceByteCounting {
    private var total: UInt64 = 0
    func totalBytes() -> UInt64 { total += 4_200_000; return total }
}
