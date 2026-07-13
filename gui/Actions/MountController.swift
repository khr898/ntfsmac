import Foundation
import HelperShared

/// Narrow seam over `HelperClient`'s two mutating methods so tests can inject a fake without a
/// real `NSXPCConnection` (`HelperClient` itself has no protocol — it's a concrete class wrapping
/// XPC directly, per `3-xpc-helper`). Declared here rather than in `gui/Helper/HelperClient.swift`
/// to keep that unit's file untouched; retroactive conformance below is same-module so no
/// `@retroactive` marker is needed.
@MainActor
public protocol HelperMounting {
    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult
    func unmount(target: String) async throws -> CommandResult
}

extension HelperClient: HelperMounting {}

/// `[Mount]`/`Unmount` (GUI-PLAN.md "Popover — idle"/"Popover — mounted") always route through
/// this controller, which always routes through the XPC helper (L5) — never a raw shell-out.
/// Drives the shared `AppState.state` icon/popover transition: idle→mounting→mounted/error.
@MainActor
public final class MountController: ObservableObject {
    @Published public private(set) var mountedDrive: Drive?
    /// The real mount point this drive was actually requested at — set at successful mount time,
    /// so `FinderOpener` can reveal the real path instead of guessing at GUI-PLAN.md's documented
    /// `/Volumes/<label>` default convention (its own doc comment already flags this as a
    /// heuristic, pending a real value being threaded through; this is that real value).
    @Published public private(set) var mountedMountPoint: String?
    @Published public private(set) var errorMessage: String?

    private let helper: any HelperMounting
    private let readOnlyChecker: any MountReadOnlyChecking
    private let appState: AppState

    public init(
        helper: any HelperMounting = HelperClient(),
        readOnlyChecker: any MountReadOnlyChecking = RealMountOptionsChecker(),
        appState: AppState
    ) {
        self.helper = helper
        self.readOnlyChecker = readOnlyChecker
        self.appState = appState
    }

    /// `mountPoint`: real, caller-resolved path (e.g. `Settings.defaultMountPoint` with
    /// `<label>` substituted) — `nil` lets anylinuxfs pick its own default under `/Volumes/`.
    /// `readOnly`: threads through to the helper's `--read-only` flag (`HelperMounting`'s real
    /// lever for `Settings.defaultMountMode == .readOnly` — see `HelperProtocol.swift`'s doc
    /// comment for why this is the only real mechanism available).
    public func mount(_ drive: Drive, driver: FsDriver = .ntfs3g, mountPoint: String? = nil, readOnly: Bool = false) async {
        // Single-mount-at-a-time invariant: without this, tapping Mount on a second drive while
        // one is already mounted (or mid-.mounting) silently overwrites `mountedDrive`/
        // `appState.state`, orphaning the first drive — still mounted through the helper with no
        // button left to unmount it. `3-mount-unmount`'s Do clause implies one active mount;
        // v2's multi-drive support is gated on upstream anyway (GUI-PLAN.md "v2").
        guard mountedDrive == nil, appState.state == .idle || appState.state == .error else {
            // Rejecting a redundant mount must not disturb whatever's actually happening
            // (e.g. a drive already mounted r/w) — no `fail()`/`.error` transition here.
            errorMessage = "A drive is already mounted or mounting; unmount it first"
            return
        }

        // Do clause: validate the device regex before the call. `HelperClient.mount` already
        // re-validates internally (defense in depth per L6), but that check is invisible to a
        // mocked `HelperMounting` in tests — this guard is what the acceptance criteria
        // ("rejection of invalid device names") actually exercises.
        guard validateDevice(drive.identifier) else {
            fail("Invalid device name: \(drive.identifier)")
            return
        }

        errorMessage = nil
        appState.state = .mounting
        do {
            let result = try await helper.mount(device: drive.identifier, driver: driver, mountPoint: mountPoint, readOnly: readOnly)
            if result.exitCode == 0 {
                mountedDrive = drive
                mountedMountPoint = mountPoint
                // A `readOnly: false` request can still land read-only: ntfs-3g silently falls
                // back to read-only on a dirty/unclean NTFS journal (same real-mount-options
                // check `RemountController.confirmRemount` already relies on — `exitCode == 0`
                // alone doesn't mean "mounted the way you asked"). Without this, a dirty landing
                // was reported as a healthy `.mountedReadWrite`, and `.mountedReadOnlyDirty` was
                // never reachable from a real mount at all — only from `RemountController`, which
                // itself is only reachable from the banner this state is supposed to trigger.
                if readOnly {
                    appState.state = .mountedReadOnly
                } else if await readOnlyChecker.isAnyNfsMountReadOnly() {
                    appState.state = .mountedReadOnlyDirty
                } else {
                    appState.state = .mountedReadWrite
                }
            } else {
                fail(result.output)
            }
        } catch {
            fail(Self.describe(error))
        }
    }

    public func unmount() async {
        guard let target = mountedDrive?.identifier else { return }
        errorMessage = nil
        do {
            let result = try await helper.unmount(target: target)
            if result.exitCode == 0 {
                mountedDrive = nil
                mountedMountPoint = nil
                appState.state = .idle
            } else {
                fail(result.output)
            }
        } catch {
            fail(Self.describe(error))
        }
    }

    private func fail(_ message: String) {
        if message.contains("Insufficient permissions?") || message.contains("Cannot probe") {
            errorMessage = "Full Disk Access required for the helper.\n\nPlease open System Settings -> Privacy & Security -> Full Disk Access, click the '+' button, press Cmd+Shift+G, enter:\n/Library/PrivilegedHelperTools/com.khr898.ntfsmac.helper\nand add it to the list."
        } else {
            errorMessage = message
        }
        appState.state = .error
    }

    /// GUI-PLAN.md "Error state": plain-language cause, not a raw Swift error dump. Not
    /// `private` — `RemountController` (`3-dirty-ro-warning`) reuses it rather than
    /// re-duplicating the same `HelperClientError` mapping.
    static func describe(_ error: Error) -> String {
        switch error {
        case HelperClientError.invalidDevice(let device):
            return "Invalid device name: \(device)"
        case HelperClientError.invalidUnmountTarget(let target):
            return "Invalid unmount target: \(target)"
        case HelperClientError.helper(let message):
            return message
        case HelperClientError.decode:
            return "Helper returned an unreadable response"
        case HelperClientError.proxyUnavailable:
            return "Privileged helper is not installed or not responding"
        default:
            return error.localizedDescription
        }
    }
}
