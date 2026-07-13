import Foundation
import ServiceManagement
import HelperShared
import os.log

private let helperInstallerLog = Logger(subsystem: "com.khr898.ntfsmac", category: "HelperInstaller")

/// Outcome of a real `SMJobBless` attempt (PLAN.md §3, L4/L5 — SMJobBless/ad-hoc signing is a
/// HARD-STOP, never deviate to `SMAppService` or a raw `sudo` shell-out).
public enum HelperInstallOutcome: Equatable, Sendable {
    case installed
    case denied(String)
    case failed(String)
}

/// Seam over `ServiceManagement`'s real, synchronous, blocking C APIs — `SMJobCopyDictionary`/
/// `SMJobBless` neither suspend nor come in an async flavor; they block the calling thread for
/// the whole (potentially long, user-driven) admin auth prompt. `Sendable`-constrained so
/// `HelperInstaller` can run this off the main actor without freezing the menu-bar UI for
/// however long the user takes to authenticate.
public protocol HelperInstallService: Sendable {
    func isInstalled(label: String) -> Bool
    func bless(label: String) -> HelperInstallOutcome
}

/// Strips `com.apple.quarantine` from this app's own bundle before every `bless()` attempt.
/// Real-world failure this exists for: the DMG is ad-hoc-signed with no notarization (L4 — no
/// paid Developer account) — on a *different* machine than it was built on, any quarantine-aware
/// transfer (download, AirDrop, etc.) tags the DMG, and macOS propagates that tag onto every file
/// Finder extracts from it, including the embedded helper tool. The user right-clicking "Open" on
/// the outer .app only approves *that* launch; `SMJobBless` then copies the helper tool *out* of
/// the bundle into `/Library/PrivilegedHelperTools/` as a standalone file, still quarantined —
/// launchd's later attempt to actually run that daemon gets silently blocked by Gatekeeper (no
/// dialog, since a background daemon has no interactive session to approve through). `bless()`
/// itself still reports success (it only copies files and registers with launchd), so this reads
/// exactly like "installed the helper" followed by "can't communicate with helper" for
/// everything — install and uninstall alike. Clearing quarantine on files this app already owns
/// is not a privileged operation (no XPC helper round-trip needed, no L5 concern).
public protocol QuarantineStripping: Sendable {
    func stripQuarantine()
}

public struct RealQuarantineStripper: QuarantineStripping {
    public init() {}

    public func stripQuarantine() {
        guard let bundleURL = Bundle.main.bundleURL as URL?,
              let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: nil)
        else { return }
        removexattr(bundleURL.path, "com.apple.quarantine", 0)
        for case let fileURL as URL in enumerator {
            removexattr(fileURL.path, "com.apple.quarantine", 0)
        }
    }
}

public struct RealHelperInstallService: HelperInstallService {
    public init() {}

    /// `SMJobCopyDictionary` is the documented, real way to check whether a `SMJobBless`-style
    /// launchd job is already registered — deliberately not `SMAppService.status` (that's the
    /// newer `SMAppService.daemon` API, a different install mechanism PLAN.md never adopted;
    /// swapping to it here would be exactly the kind of signing/entitlement architecture
    /// deviation L4/L5 calls a HARD-STOP). Still functions on macOS 13+ despite the
    /// deprecation annotation.
    ///
    /// Trust caveat (real, not new to this unit — same ad-hoc-signing tradeoff already
    /// documented in `helper/Info.plist`/`main.swift`'s `verifyClientIdentity`): this only
    /// checks that *some* job is registered under `label`, not that its on-disk binary still
    /// matches this app's expected identifier. There's no stronger check realistically
    /// available without a paid-cert trust chain (L4).
    public func isInstalled(label: String) -> Bool {
        SMJobCopyDictionary(kSMDomainSystemLaunchd, label as CFString) != nil
    }

    public func bless(label: String) -> HelperInstallOutcome {
        var authRef: AuthorizationRef?
        // `kSMRightBlessPrivilegedHelper.withCString` keeps the C string alive for exactly the
        // duration of `AuthorizationCreate` — not relying on `(kSMRightBlessPrivilegedHelper as
        // NSString).utf8String`'s pointer surviving past the bridging expression, which the
        // API contract never actually guarantees.
        let status = kSMRightBlessPrivilegedHelper.withCString { namePtr -> OSStatus in
            var authItem = AuthorizationItem(name: namePtr, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &authItem) { itemPtr -> OSStatus in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                return AuthorizationCreate(&rights, nil, flags, &authRef)
            }
        }

        guard status == errAuthorizationSuccess, let authRef else {
            switch status {
            case errAuthorizationCanceled:
                return .denied("Authorization was cancelled.")
            case errAuthorizationDenied:
                return .denied("Authorization was denied — an administrator password is required.")
            default:
                return .failed("Authorization request failed (status \(status)).")
            }
        }
        defer { AuthorizationFree(authRef, [.destroyRights]) }

        var cfError: Unmanaged<CFError>?
        guard SMJobBless(kSMDomainSystemLaunchd, label as CFString, authRef, &cfError) else {
            if let cfError {
                return .failed((cfError.takeRetainedValue() as Error).localizedDescription)
            }
            return .failed("SMJobBless failed for an unknown reason.")
        }
        return .installed
    }
}

/// Narrow seam over `HelperClient`'s `version`/`uninstallHelper` — lets `HelperInstaller` tell a
/// stale daemon (left running from a previous build, before this session's XPC-protocol/hash-pin
/// changes) apart from a current one, and clear it out. Same retroactive-conformance pattern as
/// `HelperUninstalling`/`CLIStaging` — `HelperClient` wraps a real `NSXPCConnection`, no seam of
/// its own to fake in tests.
@MainActor
public protocol StaleHelperDetecting: Sendable {
    func version() async throws -> String
    func uninstallHelper() async throws -> CommandResult
}

extension HelperClient: StaleHelperDetecting {}

public enum HelperInstallState: Equatable, Sendable {
    case notChecked
    case checking
    case installed
    case installing
    case denied(String)
    case failed(String)

    /// Drives the menu-bar icon red (`ui/prototype.html`'s "Error — Helper Missing" state,
    /// `NtfsmacApp.swift`) — the only two states where the user actually needs to act.
    public var isDeniedOrFailed: Bool {
        switch self {
        case .denied, .failed: true
        case .notChecked, .checking, .installed, .installing: false
        }
    }
}

/// Drives the privileged-helper install flow (GUI-PLAN.md v1 feature 8): exactly one auth
/// prompt, detects already-installed and skips it, denial/mismatch surfaces a plain-language
/// cause + lets the caller retry (red icon in `FirstRunView`). `install()` is the exact same
/// path both first-run and the Preferences "Reinstall privileged helper" button use — this
/// unit's Do clause requires that reuse, so there's deliberately no separate "reinstall" method.
@MainActor
public final class HelperInstaller: ObservableObject {
    @Published public private(set) var state: HelperInstallState = .notChecked

    private let service: any HelperInstallService
    private let staleDetector: any StaleHelperDetecting
    private let quarantineStripper: any QuarantineStripping
    private let label: String
    private let expectedVersion: String
    private let staleCheckTimeoutNanoseconds: UInt64

    public init(
        service: any HelperInstallService = RealHelperInstallService(),
        staleDetector: any StaleHelperDetecting = HelperClient(),
        quarantineStripper: any QuarantineStripping = RealQuarantineStripper(),
        label: String = helperMachServiceName,
        expectedVersion: String = GeneratedCLIManifest.expectedTreeHashHex,
        staleCheckTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.service = service
        self.staleDetector = staleDetector
        self.quarantineStripper = quarantineStripper
        self.label = label
        self.expectedVersion = expectedVersion
        self.staleCheckTimeoutNanoseconds = staleCheckTimeoutNanoseconds
    }

    /// First-run entry point: detect already-installed and skip (Do clause) — never re-prompts
    /// for an install that's already live. Guards against a stray re-trigger (e.g. SwiftUI
    /// `.task` re-running) while a check/install is already in flight, and — critically — against
    /// re-running after a `.denied`/`.failed` outcome: `MenuBarExtra(.window)` recreates
    /// `FirstRunView` (and refires its `.task`) every time the popover reopens, so without this
    /// guard closing and reopening the menu after a denial re-triggers `bless()` and shows a new
    /// OS auth prompt with no user action. Only the explicit "Retry" button (which calls
    /// `install()` directly) may attempt again once denied/failed.
    ///
    /// "already installed" per `SMJobCopyDictionary` only proves *some* job is registered under
    /// `label` (`RealHelperInstallService.isInstalled`'s own doc comment) — it says nothing about
    /// whether that daemon is *this build's* helper. A daemon left running from an earlier build
    /// (common mid-development, rebuilding the app without ever un-blessing the old helper) is
    /// live enough to satisfy that check while being out of protocol sync with the current GUI —
    /// exactly the failure mode behind both a permanently-stuck "Setup incomplete" (`stageCLI`
    /// rejects on the hash it was actually built with) and "couldn't connect with helper"
    /// (`removeDependencies`/`uninstallHelper` calls hitting a daemon that doesn't match). So a
    /// registered helper only counts as installed if it reports the same build hash this GUI was
    /// built with; otherwise it's cleared out (best-effort, via its own still-live
    /// `uninstallHelper` — works for any helper new enough to have that method, i.e. everything
    /// from this point forward) and a fresh `bless()` runs, same single-auth-prompt path a
    /// first-time install takes.
    public func installIfNeeded() async {
        switch state {
        case .checking, .installing, .denied, .failed:
            return
        case .notChecked, .installed:
            break
        }
        state = .checking
        let alreadyInstalled = await runOffCooperativePool { [service, label] in service.isInstalled(label: label) }
        guard alreadyInstalled else {
            await install()
            return
        }
        if await isRegisteredHelperCurrent() {
            state = .installed
            return
        }
        // Bounded, same reason `isRegisteredHelperCurrent` below is: a helper old enough to
        // predate `uninstallHelper` itself (or one that's simply wedged) must not be able to
        // hang this indefinitely — worst case, `bless()` still runs next and SMJobBless's own
        // install path takes over from whatever state the stale daemon was left in.
        // Silent-failure-hunter finding (2026-07-13, MEDIUM): this result was fully discarded
        // with no logging — a real failure clearing the stale daemon (e.g. a permission error
        // deleting its plist, not just a timeout) then surfaced only as a generic `bless()`
        // failure next, with no trail pointing back at the actual root cause. Best-effort
        // discard-and-continue is still correct (SMJobBless's own install path recovers
        // regardless), but it should leave a diagnostic trail.
        let staleUninstallResult = await withStaleCheckTimeout { [staleDetector] in try await staleDetector.uninstallHelper() }
        if let staleUninstallResult {
            helperInstallerLog.notice("stale helper uninstall: exitCode=\(staleUninstallResult.exitCode, privacy: .public) output=\(staleUninstallResult.output, privacy: .public)")
        } else {
            helperInstallerLog.notice("stale helper uninstall: no response within timeout (wedged or predates uninstallHelper)")
        }
        await install()
    }

    public func reset() {
        state = .notChecked
    }

    /// A daemon old enough to predate `version()` entirely doesn't just fail to answer — an XPC
    /// message for a selector the exported interface never declared can leave the reply
    /// continuation unresolved rather than erroring cleanly (the exact hang class `HelperClient`'s
    /// `call()` already documents fixing for the *known* protocol; an *unknown* future one is the
    /// same risk in the other direction). `withStaleCheckTimeout` bounds it: no matter how an old
    /// or wedged helper actually fails, staleness detection resolves within
    /// `staleCheckTimeoutNanoseconds` and reads as stale, never blocks `installIfNeeded()` forever.
    private func isRegisteredHelperCurrent() async -> Bool {
        guard let reported = await withStaleCheckTimeout({ [staleDetector] in try await staleDetector.version() }) else { return false }
        return reported == expectedVersion
    }

    private func withStaleCheckTimeout<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        let timeoutNanoseconds = staleCheckTimeoutNanoseconds
        return await withTaskGroup(of: T?.self) { group in
            group.addTask {
                try? await work()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Unconditional install/reinstall — the one path both `installIfNeeded()` and any future
    /// "Reinstall privileged helper" caller use. Guards against a double-tap firing two
    /// concurrent `SMJobBless` calls (each would show its own OS auth prompt).
    public func install() async {
        guard state != .installing else { return }
        state = .installing
        let outcome = await runOffCooperativePool { [service, label, quarantineStripper] in
            quarantineStripper.stripQuarantine()
            return service.bless(label: label)
        }
        switch outcome {
        case .installed:
            state = .installed
        case .denied(let message):
            state = .denied(message)
        case .failed(let message):
            state = .failed(message)
        }
    }

    /// `SMJobCopyDictionary`/`SMJobBless` block for an indefinite, user-driven duration (the
    /// system auth prompt) — dispatched to a dedicated GCD queue, not `Task.detached` (which
    /// would occupy a slot on Swift Concurrency's small, shared cooperative thread pool for
    /// that entire indefinite wait, starving unrelated `async` work elsewhere in the process).
    private nonisolated func runOffCooperativePool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}
