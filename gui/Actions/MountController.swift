import Foundation
import HelperShared

/// Narrow seam over `HelperClient`'s two mutating methods so tests can inject a fake without a
/// real `NSXPCConnection` (`HelperClient` itself has no protocol — it's a concrete class wrapping
/// XPC directly, per `3-xpc-helper`). Declared here rather than in `gui/Helper/HelperClient.swift`
/// to keep that unit's file untouched; retroactive conformance below is same-module so no
/// `@retroactive` marker is needed.
@MainActor
public protocol HelperMounting {
    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool, recoveryKey: String?) async throws -> CommandResult
    func unmount(target: String) async throws -> CommandResult
}

extension HelperClient: HelperMounting {}

/// One mounted drive: the `Drive` plus its real mount point and per-drive read-only/dirty
/// landing state. Multi-mount (PLAN.md / GUI-PLAN.md "v2") means the controller holds a list
/// of these, not a single optional drive. `isDirty` is per-drive so `DriveRow`'s
/// "Mount read/write anyway…" pill can surface on exactly the row that landed read-only on a
/// dirty NTFS journal, not on every mounted row.
public struct MountedDrive: Identifiable, Equatable, Sendable {
    public let drive: Drive
    public var mountPoint: String?
    public var isReadOnly: Bool
    public var isDirty: Bool
    public var isVerified: Bool
    public var id: String { drive.id }

    public init(
        drive: Drive,
        mountPoint: String?,
        isReadOnly: Bool,
        isDirty: Bool,
        isVerified: Bool = true
    ) {
        self.drive = drive
        self.mountPoint = mountPoint
        self.isReadOnly = isReadOnly
        self.isDirty = isDirty
        self.isVerified = isVerified
    }
}

/// `[Mount]`/`Unmount` (GUI-PLAN.md "Popover — idle"/"Popover — mounted") always route through
/// this controller, which always routes through the XPC helper (L5) — never a raw shell-out.
/// Drives the shared `AppState.state` icon/popover transition: idle→mounting→mounted/error.
/// Supports multiple concurrent mounts (mixed NTFS + ext) — each mount is an independent
/// anylinuxfs microVM on its own vmnet /30 subnet (anylinuxfs `netutil::pick_available_network`
/// allocates a distinct subnet per mount), so the controller only has to track N entries and
/// keep the aggregate icon state correct.
@MainActor
public final class MountController: ObservableObject {
    @Published public private(set) var mountedDrives: [MountedDrive] = []
    @Published public internal(set) var errorMessage: String?
    @Published public private(set) var reconciliationWarning: String?
    @Published public private(set) var credentialRequiredDeviceID: String?

    private let helper: any HelperMounting
    private let readOnlyChecker: any MountReadOnlyChecking
    private let snapshotProvider: any MountSnapshotProviding
    private let appState: AppState
    private var pollTask: Task<Void, Never>?
    /// Polling continues while a helper call is in flight. Preserve the visible `.mounting`
    /// state until that call resolves; an authoritative empty snapshot during VM boot is not a
    /// completed unmount and must not make the UI offer a second Mount action.
    private var mountOperationsInFlight = 0
    /// A status-only session can be a transient observation while macOS refreshes its mount
    /// table, or it can mean Finder removed the NFS share behind ntfsmac's back. Require the same
    /// inconsistency twice before asking the helper to tear down the orphaned anylinuxfs session.
    /// An authoritative disappearance needs no debounce, but still routes through the helper so
    /// stale VM/PF/route state is cleaned instead of only disappearing from the GUI.
    private var pendingExternalUnmounts: Set<String> = []

    public init(
        helper: any HelperMounting = HelperClient(),
        readOnlyChecker: any MountReadOnlyChecking = RealMountOptionsChecker(),
        snapshotProvider: (any MountSnapshotProviding)? = nil,
        appState: AppState
    ) {
        self.helper = helper
        self.readOnlyChecker = readOnlyChecker
        self.snapshotProvider = snapshotProvider
            ?? (helper as? any MountSnapshotProviding)
            ?? RealMountSnapshotProvider()
        self.appState = appState
    }

    deinit {
        pollTask?.cancel()
    }

    /// Derive the helper driver from the parsed fstype when the caller didn't pin one. ext-family
    /// (GPT-name fallback "ext" or blkid "ext2/3/4") → `.ext` so the helper skips --fs-driver and
    /// passes --ignore-permissions; everything else (ntfs, BitLocker) → `.ntfs3g`. `hasPrefix`
    /// is safe here — `DriveListParser.allowedFsTypes` is the only producer of fsType and the
    /// only value starting with "ext" is the ext family. NTFS never routes to `.ext`.
    static func driverFor(_ fsType: String) -> FsDriver {
        fsType.hasPrefix("ext") ? .ext : .ntfs3g
    }

    // MARK: - Back-compat single-drive accessors
    // `PopoverContentView`/`FinderOpener` and existing tests read the "primary" mounted drive
    // and its mount point. With N drives these return the first — the per-row UI in
    // `PopoverContentView` renders from `mountedDrives`/`mountedDriveIDs` directly, so these
    // accessors only feed the icon/banner and the Finder-reveal of the first mount.

    /// First mounted drive, or nil if nothing is mounted (primary-drive compat).
    public var mountedDrive: Drive? { mountedDrives.first?.drive }
    /// First mounted drive's real mount point, or nil (primary-drive compat).
    public var mountedMountPoint: String? { mountedDrives.first?.mountPoint }
    /// Identifiers of every currently mounted drive — used by `DriveListView` to mark rows.
    public var mountedDriveIDs: Set<String> { Set(mountedDrives.map(\.id)) }

    /// Reconcile on launch and every bounded polling interval. The closure is evaluated on the
    /// main actor so the scanner's latest `@Published` drive metadata can be reused safely.
    public func startPolling(
        knownDrives: @escaping @MainActor () -> [Drive],
        interval: Duration = .seconds(5)
    ) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.reconcile(knownDrives: knownDrives())
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func dismissCredentialRequest() {
        credentialRequiredDeviceID = nil
    }

    /// Refreshes GUI state from two independent host sources. An authoritative empty snapshot
    /// clears stale rows after CLI/external unmounts; incomplete evidence preserves rows but marks
    /// them unverified so the UI can never remain falsely green.
    @discardableResult
    public func reconcile(knownDrives: [Drive]) async -> MountSnapshot {
        var snapshot = await snapshotProvider.snapshot()
        let trackedIDs = Set(mountedDrives.map(\.id))
        let verifiedIDs = Set(mountedDrives.filter(\.isVerified).map(\.id))
        let observedIDs = Set(snapshot.mounts.map(\.deviceIdentifier))
        var cleanupIDs: Set<String> = []

        if snapshot.isAuthoritative {
            // Both sources agree the mount is gone. Include a previously debounced status-only
            // session even though its cached row is no longer verified.
            cleanupIDs = verifiedIDs
                .union(pendingExternalUnmounts)
                .subtracting(observedIDs)
            pendingExternalUnmounts.subtract(observedIDs)
        } else if snapshot.warningCode == "MOUNT_STATE_INCONSISTENT" {
            let statusOnlyIDs = Set(snapshot.mounts.compactMap { mount in
                mount.isReadOnly == nil ? mount.deviceIdentifier : nil
            })
            let eligible = statusOnlyIDs
                .intersection(trackedIDs)
                .intersection(verifiedIDs.union(pendingExternalUnmounts))
            cleanupIDs = eligible.intersection(pendingExternalUnmounts)
            pendingExternalUnmounts = eligible
        } else {
            // A failed source is not proof of an external unmount. Forget the debounce rather
            // than turning an unrelated diagnostic outage into a privileged mutation later.
            pendingExternalUnmounts.removeAll()
        }

        if !cleanupIDs.isEmpty {
            var cleanupFailed = false
            for device in cleanupIDs.sorted() {
                do {
                    let result = try await helper.unmount(target: device)
                    if result.exitCode != 0 {
                        cleanupFailed = true
                        break
                    }
                } catch {
                    cleanupFailed = true
                    break
                }
            }

            if cleanupFailed {
                apply(snapshot, knownDrives: knownDrives)
                let message = "EXTERNAL_UNMOUNT_CLEANUP_UNPROVEN — the NFS share disappeared, but private session cleanup could not be verified"
                errorMessage = message
                reconciliationWarning = message
                if mountedDrives.isEmpty {
                    appState.state = .error
                }
                return snapshot
            }

            pendingExternalUnmounts.subtract(cleanupIDs)
            // The helper response is provisional just like mount/unmount responses elsewhere:
            // publish only the fresh host/runtime observation after the cleanup attempt.
            snapshot = await snapshotProvider.snapshot()
        }

        apply(snapshot, knownDrives: knownDrives)
        return snapshot
    }

    /// `mountPoint`: real, caller-resolved path (e.g. `Settings.defaultMountPoint` with
    /// `<label>` substituted) — `nil` lets anylinuxfs pick its own default under `/Volumes/`.
    /// `readOnly`: threads through to the helper's `--read-only` flag (`HelperMounting`'s real
    /// lever for `Settings.defaultMountMode == .readOnly` — see `HelperProtocol.swift`'s doc
    /// comment for why this is the only real mechanism available).
    /// `driver`: `nil` (the default — what `PopoverContentView`'s `mountDrive` passes) derives
    /// from `drive.fsType`: ext-family → `.ext` (helper skips --fs-driver, adds
    /// --ignore-permissions for all_squash), anything else → `.ntfs3g`. An explicit driver
    /// overrides — preserved for a future ntfs3 preference and for tests that pin the value.
    public func mount(_ drive: Drive, driver: FsDriver? = nil, mountPoint: String? = nil, readOnly: Bool = false, recoveryKey: String? = nil) async {
        // Do clause: validate the device regex before the call. `HelperClient.mount` already
        // re-validates internally (defense in depth per L6), but that check is invisible to a
        // mocked `HelperMounting` in tests — this guard is what the acceptance criteria
        // ("rejection of invalid device names") actually exercises.
        guard validateDevice(drive.identifier) else {
            fail("Invalid device name: \(drive.identifier)")
            return
        }

        errorMessage = nil
        credentialRequiredDeviceID = nil
        reconciliationWarning = nil
        mountOperationsInFlight += 1
        appState.state = .mounting
        defer {
            mountOperationsInFlight -= 1
            if appState.state == .mounting {
                recomputeAggregateState()
            }
        }
        do {
            let resolvedDriver = driver ?? Self.driverFor(drive.fsType)
            let result = try await helper.mount(device: drive.identifier, driver: resolvedDriver, mountPoint: mountPoint, readOnly: readOnly, recoveryKey: recoveryKey)
            if result.exitCode == 0 {
                let resolvedMountPoint: String?
                if let mountPoint = mountPoint {
                    resolvedMountPoint = mountPoint
                } else {
                    // Parse the actual mount point from the command output, e.g.:
                    // "/dev/disk4s2 was mounted as /Volumes/My Drive"
                    let lines = result.output.components(separatedBy: .newlines)
                    if let mountLine = lines.first(where: { $0.contains(" was mounted as ") }),
                       let range = mountLine.range(of: " was mounted as ") {
                        let path = String(mountLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                        resolvedMountPoint = path
                    } else {
                        // Fallback to the heuristic
                        resolvedMountPoint = "/Volumes/\(drive.label.isEmpty ? drive.identifier : drive.label)"
                    }
                }
                // The helper response is provisional. Do not publish green until the host mount
                // table and anylinuxfs runtime independently observe this exact device.
                let snapshot = await snapshotProvider.snapshot()
                apply(snapshot, knownDrives: [drive])
                let observed = snapshot.mounts.first { $0.deviceIdentifier == drive.identifier }
                if snapshot.isAuthoritative && observed == nil {
                    mountedDrives.removeAll { $0.id == drive.identifier }
                    fail("MOUNT_NOT_OBSERVED — the helper returned success but no matching host mount exists")
                    return
                }

                // A read/write request can still land read-only on an unclean NTFS journal.
                // Prefer the per-mount host option; retain the existing checker as a conservative
                // fallback when the snapshot could not pair the status and mount-table rows.
                let fallbackReadOnly = observed?.isReadOnly == nil
                    ? await readOnlyChecker.isAnyNfsMountReadOnly()
                    : false
                let landedReadOnly = readOnly || (observed?.isReadOnly ?? fallbackReadOnly)
                if let index = mountedDrives.firstIndex(where: { $0.id == drive.identifier }) {
                    mountedDrives[index].mountPoint = observed?.mountPoint ?? resolvedMountPoint
                    mountedDrives[index].isReadOnly = landedReadOnly
                    mountedDrives[index].isDirty = landedReadOnly && !readOnly
                    mountedDrives[index].isVerified = snapshot.isAuthoritative && observed?.isReadOnly != nil
                } else {
                    mountedDrives.append(MountedDrive(
                        drive: drive,
                        mountPoint: resolvedMountPoint,
                        isReadOnly: landedReadOnly,
                        isDirty: landedReadOnly && !readOnly,
                        isVerified: false
                    ))
                    reconciliationWarning = warningMessage(for: snapshot.warningCode ?? "MOUNT_STATE_SOURCE_UNAVAILABLE")
                }
                recomputeAggregateState()
            } else {
                if result.output.contains("BITLOCKER_CREDENTIAL_REQUIRED") {
                    credentialRequiredDeviceID = drive.identifier
                    recomputeAggregateState()
                } else {
                    fail(result.output)
                }
            }
        } catch {
            fail(Self.describe(error))
        }
    }

    /// Unmount one drive by id, or every mounted drive when `driveID` is nil. Each unmount is an
    /// independent `helper.unmount(target:)` call (one anylinuxfs session per drive).
    public func unmount(driveID: String? = nil) async {
        errorMessage = nil
        reconciliationWarning = nil
        let targets: [String]
        if let driveID {
            guard mountedDrives.contains(where: { $0.id == driveID }) else { return }
            targets = [driveID]
        } else {
            targets = mountedDrives.map(\.id)
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            do {
                let result = try await helper.unmount(target: target)
                if result.exitCode != 0 {
                    fail(result.output)
                    recomputeAggregateState()
                    return
                }
            } catch {
                fail(Self.describe(error))
                recomputeAggregateState()
                return
            }
        }
        let snapshot = await snapshotProvider.snapshot()
        apply(snapshot, knownDrives: mountedDrives.map(\.drive))
        let stillMounted = Set(targets).intersection(mountedDriveIDs)
        if !stillMounted.isEmpty {
            for index in mountedDrives.indices where stillMounted.contains(mountedDrives[index].id) {
                mountedDrives[index].isVerified = false
            }
            reconciliationWarning = warningMessage(for: "UNMOUNT_NOT_OBSERVED")
            recomputeAggregateState()
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    private func apply(_ snapshot: MountSnapshot, knownDrives: [Drive]) {
        let previous = Dictionary(uniqueKeysWithValues: mountedDrives.map { ($0.id, $0) })
        let known = Dictionary(uniqueKeysWithValues: knownDrives.map { ($0.id, $0) })
        var updated = snapshot.mounts.map { observed -> MountedDrive in
            let prior = previous[observed.deviceIdentifier]
            let drive = known[observed.deviceIdentifier]
                ?? prior?.drive
                ?? fallbackDrive(for: observed)
            return MountedDrive(
                drive: drive,
                mountPoint: observed.mountPoint,
                isReadOnly: observed.isReadOnly ?? prior?.isReadOnly ?? true,
                isDirty: prior?.isDirty ?? false,
                isVerified: observed.isReadOnly != nil && snapshot.isAuthoritative
            )
        }

        if !snapshot.isAuthoritative {
            let observedIDs = Set(updated.map(\.id))
            for var cached in mountedDrives where !observedIDs.contains(cached.id) {
                cached.isVerified = false
                updated.append(cached)
            }
        }

        mountedDrives = updated.sorted { $0.id < $1.id }
        reconciliationWarning = mountedDrives.isEmpty
            ? nil
            : snapshot.warningCode.map { warningMessage(for: $0) }
        recomputeAggregateState()
    }

    private func fallbackDrive(for observed: ObservedMount) -> Drive {
        let fsType: String
        switch observed.fsDriver {
        case "ntfs-3g", "ntfs3": fsType = "ntfs"
        case let driver? where driver.hasPrefix("ext"): fsType = driver
        default: fsType = "unknown"
        }
        let label = URL(fileURLWithPath: observed.mountPoint).lastPathComponent
        return Drive(
            identifier: observed.deviceIdentifier,
            fsType: fsType,
            label: label,
            size: ""
        )
    }

    private func warningMessage(for code: String) -> String {
        switch code {
        case "MOUNT_STATE_INCONSISTENT":
            return "MOUNT_STATE_INCONSISTENT — runtime and host mount table disagree"
        case "UNMOUNT_NOT_OBSERVED":
            return "UNMOUNT_NOT_OBSERVED — the drive is still present in the host mount table"
        default:
            return "MOUNT_STATE_SOURCE_UNAVAILABLE — mounted state could not be independently verified"
        }
    }

    /// Derive the shared icon/banner state from the full mounted set. The icon reflects the
    /// worst landing across all drives: any dirty → dirty banner; else any ro → read-only;
    /// else read/write; empty → idle. `.mounting` is set imperatively at mount start and
    /// overwritten here once the mount resolves.
    private func recomputeAggregateState() {
        if mountOperationsInFlight > 0 {
            appState.state = .mounting
        } else if mountedDrives.isEmpty {
            appState.state = .idle
        } else if mountedDrives.contains(where: { !$0.isVerified }) {
            appState.state = .mountedUnknown
        } else if mountedDrives.contains(where: { $0.isDirty }) {
            appState.state = .mountedReadOnlyDirty
        } else if mountedDrives.contains(where: { $0.isReadOnly }) {
            appState.state = .mountedReadOnly
        } else {
            appState.state = .mountedReadWrite
        }
    }

    private func fail(_ message: String) {
        // A failed mount/unmount while other drives are still mounted must not flip the icon to
        // `.error` and hide the "mounted" indicator — only go `.error` when nothing is mounted.
        if message.contains("Insufficient permissions?") || message.contains("Cannot probe") {
            errorMessage = "FDA_REQUIRED"
        } else {
            errorMessage = message
        }
        if mountedDrives.isEmpty {
            appState.state = .error
        }
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
