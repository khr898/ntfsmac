import Foundation
import HelperShared

/// Narrow seam over `HelperClient.stageCLI` — same DI pattern `MountController`'s
/// `HelperMounting` already uses, so tests never need a real `NSXPCConnection`.
@MainActor
public protocol CLIStaging {
    func stageCLI(installScriptPath: String) async throws -> CommandResult
}

extension HelperClient: CLIStaging {}

/// Runs once a fresh helper install completes: stages the CLI/vendored binaries in the
/// background via the bundled `install.sh` (`HelperService.stageCLI`, already root) so a
/// GUI-only install needs zero separate Terminal step — the explicit product requirement this
/// exists for. A no-op if the CLI is already present (any install path) or already attempted
/// this launch; never retried silently in a loop if staging fails automatically — `retry()` is
/// the deliberate exception, an explicit user tap on `CLIMissingView`'s button, never called on a
/// timer or from `stageIfNeeded()` itself. `lastFailureReason` is `ObservableObject`-published
/// so that button can show *why* setup didn't complete instead of a generic dead end.
@MainActor
public final class CLIAutoStager: ObservableObject {
    @Published public private(set) var lastFailureReason: String?

    private let helper: any CLIStaging
    private let checker: CLIInstallChecker
    private let bundleResourcesURL: URL?
    private let connectionRetryDelayNanoseconds: UInt64
    private var didAttempt = false

    /// `connectionRetryDelayNanoseconds` injectable same as `HelperInstaller.staleCheckTimeoutNanoseconds`
    /// — production default is a real ~4s bounded wait for a cold `launchd` daemon spin-up right
    /// after `SMJobBless`; tests inject a near-zero delay so exercising all
    /// `connectionRetryAttempts` doesn't make the suite itself slow.
    public init(
        helper: any CLIStaging = HelperClient(),
        checker: CLIInstallChecker,
        bundleResourcesURL: URL? = Bundle.main.resourceURL,
        connectionRetryDelayNanoseconds: UInt64 = 800_000_000
    ) {
        self.helper = helper
        self.checker = checker
        self.bundleResourcesURL = bundleResourcesURL
        self.connectionRetryDelayNanoseconds = connectionRetryDelayNanoseconds
    }

    public func stageIfNeeded() async {
        guard !didAttempt else { return }
        checker.check()
        guard !checker.isInstalled else { return }
        guard bundleResourcesURL != nil else { return }
        didAttempt = true
        await attemptStage()
    }

    /// User-initiated retry from `CLIMissingView` — bypasses the one-shot `didAttempt` guard
    /// deliberately. Safe to call repeatedly on button taps; each call is its own attempt, not a
    /// loop this class drives on its own.
    public func retry() async {
        await attemptStage()
    }

    /// Bounded retry for the *connection*, not the install: right after a fresh `SMJobBless`,
    /// launchd has registered the job but the daemon process may not be listening yet, so the
    /// very first XPC call here can lose that race and throw a connection-level error (Apple's
    /// own "Couldn't communicate with a helper application.") that has nothing to do with
    /// `install.sh` itself. Safe to blanket-retry any thrown error: `stageCLI` only ever throws
    /// on its own input-validation guards or a broken connection — a real `install.sh` failure
    /// always replies with XPC success (nonzero `exitCode`, handled below, never retried).
    /// 6 attempts at the (injectable) `connectionRetryDelayNanoseconds` apart — production default
    /// totals ~4s, matching `HelperInstaller.staleCheckTimeoutNanoseconds`'s existing bounded-wait
    /// budget for the identical "daemon just blessed, not listening yet" race. The original
    /// 3×300ms (~900ms) budget was too tight for a cold launchd spin-up (codesign verification +
    /// first process launch), which surfaced as a permanent "setup incomplete" needing a manual
    /// Retry or app restart to clear — `HelperClient` now also self-heals a dead connection on
    /// retry (see its `currentConnection()`), so this is the belt to that fix's suspenders for the
    /// pure-timing residual.
    private static let connectionRetryAttempts = 6

    private func attemptStage() async {
        checker.check()
        guard !checker.isInstalled else {
            lastFailureReason = nil
            return
        }
        guard let resourcesURL = bundleResourcesURL else {
            lastFailureReason = "ntfsmac.app is missing its bundled setup resources — reinstall the app."
            return
        }

        let installScriptPath = resourcesURL.appendingPathComponent("cli-src/install.sh").path
        for attempt in 1...Self.connectionRetryAttempts {
            do {
                let result = try await helper.stageCLI(installScriptPath: installScriptPath)
                // Silent-failure-hunter finding (2026-07-13, CRITICAL): `stageCLI` only *throws* on
                // its own input-validation guards — a real `install.sh` failure (bad arch, codesign
                // failure) still replies with XPC success, carrying a nonzero exitCode and the real
                // diagnostic text in `result.output`. Discarding the result here silently dropped
                // that text, contradicting this class's own doc comment about `lastFailureReason`.
                guard result.exitCode == 0 else {
                    lastFailureReason = result.output
                    checker.check()
                    return
                }
                lastFailureReason = nil
                checker.check()
                return
            } catch {
                guard attempt < Self.connectionRetryAttempts else {
                    lastFailureReason = MountController.describe(error)
                    checker.check()
                    return
                }
                try? await Task.sleep(nanoseconds: connectionRetryDelayNanoseconds)
            }
        }
    }
}
