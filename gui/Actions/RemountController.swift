import Foundation
import HelperShared

/// Real, unprivileged post-remount check — whether the mount actually landed read-write, not
/// just whether the helper call exited 0. Production impl runs `mount -t nfs` (same source
/// `cli/commands/diagnose.sh`'s `current_mounts()` already reads) and checks for a `read-only`
/// token in the live options. Given this app's single-mount-at-a-time invariant
/// (`MountController`'s guard), "any NFS mount is read-only" is unambiguous for a drive this
/// app just (re)mounted — there is no per-mount-point disambiguation needed in that scope.
public protocol MountReadOnlyChecking: Sendable {
    func isAnyNfsMountReadOnly() async -> Bool
}

public struct RealMountOptionsChecker: MountReadOnlyChecking {
    public init() {}

    /// Performance-optimizer finding (2026-07-13, MEDIUM): this ran `Process().waitUntilExit()`
    /// synchronously on whichever actor called it — both call sites are `@MainActor`, so this
    /// blocked the menu-bar UI for the subprocess's duration. Hopped off the cooperative pool
    /// via a dedicated queue (same pattern `HelperInstaller.runOffCooperativePool` already uses
    /// for its own blocking `ServiceManagement` calls) rather than `Task.detached`.
    public func isAnyNfsMountReadOnly() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/sbin/mount")
                process.arguments = ["-t", "nfs"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output.contains("read-only"))
            }
        }
    }
}

/// `Mount read/write anyway` (GUI-PLAN.md "Read-only (dirty) state"): re-mount via the XPC
/// helper (L5) only after an explicit confirm — never silently, never auto-remount r/w (this
/// unit's Don't clause). Reuses `HelperMounting`/`MountController.describe` from
/// `MountController.swift` (same seam, same module) instead of a second protocol/error mapper.
@MainActor
public final class RemountController: ObservableObject {
    // Not `private(set)`: SwiftUI's `.confirmationDialog(isPresented:)` needs a two-way
    // `Binding<Bool>` (a swipe-to-dismiss/Escape sets this false directly) — the actual "gated
    // behind confirm" invariant lives in `confirmRemount()`'s guards below, not in this
    // property's write-access.
    @Published public var isConfirmingRemount = false
    @Published public private(set) var isRemounting = false
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

    /// Opens the confirm dialog — never remounts directly. `DirtyBannerView`'s button calls
    /// this, not `confirmRemount` (acceptance: "remount is gated behind confirm").
    public func requestRemount() {
        guard !isRemounting else { return }
        isConfirmingRemount = true
    }

    public func cancelRemount() {
        isConfirmingRemount = false
    }

    /// Only takes effect once `requestRemount()` has actually opened the dialog — protects
    /// against a stray call skipping the confirm step even if a future caller forgets to gate
    /// on the dialog's own presentation state. `isRemounting` blocks a second concurrent call
    /// (double-tap while the first `await` is still in flight) from firing a second privileged
    /// mount RPC for the same device — the same class of race `MountController.mount()` already
    /// guards against.
    public func confirmRemount(_ drive: Drive, driver: FsDriver = .ntfs3g) async {
        guard isConfirmingRemount, !isRemounting else { return }
        isConfirmingRemount = false
        isRemounting = true
        defer { isRemounting = false }

        guard validateDevice(drive.identifier) else {
            fail("Invalid device name: \(drive.identifier)")
            return
        }

        appState.state = .mounting
        do {
            // Always `readOnly: false` — "Mount read/write anyway" is explicitly the user
            // overriding the dirty-journal read-only fallback, never a read-only request.
            let result = try await helper.mount(device: drive.identifier, driver: driver, mountPoint: nil, readOnly: false)
            guard result.exitCode == 0 else {
                fail(result.output)
                return
            }
            // Do NOT optimistically claim success: the CLI has no override for ntfs-3g's
            // dirty-journal read-only fallback (`cmd_mount.rs`'s `media_writable()` check, no
            // `force` field on `MountCmd` in `cli.rs` — only `StopCmd` has one, for
            // force-unmount), so a re-mount of a still-dirty volume can silently land read-only
            // again with `exitCode == 0`. Verify for real before telling the user it's safe to
            // write.
            if await readOnlyChecker.isAnyNfsMountReadOnly() {
                errorMessage = "Still read-only — the drive's journal is still unclean. Eject safely in Windows to enable writing."
                appState.state = .mountedReadOnlyDirty
            } else {
                errorMessage = nil
                appState.state = .mountedReadWrite
            }
        } catch {
            fail(MountController.describe(error))
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        appState.state = .error
    }
}
