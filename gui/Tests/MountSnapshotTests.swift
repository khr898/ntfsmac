import HelperShared
import Testing
@testable import NtfsmacGUI

@MainActor
private final class MutableSnapshotProvider: MountSnapshotProviding {
    var value: MountSnapshot

    init(_ value: MountSnapshot) {
        self.value = value
    }

    func snapshot() async -> MountSnapshot { value }
}

@MainActor
private final class SuccessfulHelper: HelperMounting {
    private(set) var unmountCalls: [String] = []
    var unmountResult = CommandResult(output: "unmounted", exitCode: 0)

    func mount(
        device: String,
        driver: FsDriver,
        mountPoint: String?,
        readOnly: Bool,
        recoveryKey: String?
    ) async throws -> CommandResult {
        CommandResult(
            output: "/dev/\(device) was mounted as \(mountPoint ?? "/Volumes/\(device)")",
            exitCode: 0
        )
    }

    func unmount(target: String) async throws -> CommandResult {
        unmountCalls.append(target)
        return unmountResult
    }
}

@MainActor
private final class DelayedMountHelper: HelperMounting {
    func mount(
        device: String,
        driver: FsDriver,
        mountPoint: String?,
        readOnly: Bool,
        recoveryKey: String?
    ) async throws -> CommandResult {
        try await Task.sleep(for: .milliseconds(150))
        return CommandResult(output: "mount failed after delay", exitCode: 1)
    }

    func unmount(target: String) async throws -> CommandResult {
        CommandResult(output: "unused", exitCode: 0)
    }
}

private struct AlwaysReadWrite: MountReadOnlyChecking {
    func isAnyNfsMountReadOnly() async -> Bool { false }
}

private struct SnapshotCommandRunner: PrivilegedCommandRunning {
    let status: CommandResult
    let mount: CommandResult

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        executablePath == "/test/anylinuxfs" ? status : mount
    }

    func runPipingStdin(
        _ input: String,
        to executablePath: String,
        _ arguments: [String]
    ) -> CommandResult {
        CommandResult(output: "unused", exitCode: 1)
    }
}

@Test func parsesAnyLinuxFSStatusWithoutRetainingMountedByIdentity() {
    let output = """
    /dev/disk6s1 on /Volumes/My Drive (ntfs-3g, mounted by local-user) VM[cpus: 2, ram: 1024 MiB]
    malformed diagnostic line
    disk7s2 on /Volumes/Linux (ext4, ro, mounted by another-user) VM[cpus: 2, ram: 1024 MiB]
    """

    let mounts = AnyLinuxFSStatusParser.parse(output)

    #expect(mounts.count == 2)
    #expect(mounts[0].deviceIdentifier == "disk6s1")
    #expect(mounts[0].mountPoint == "/Volumes/My Drive")
    #expect(mounts[0].fsDriver == "ntfs-3g")
    #expect(mounts.allSatisfy { !$0.mountPoint.contains("user") })
}

@Test func parsesHostNfsMountOptionsAndDeviceHostnameSuffix() {
    let output = """
    disk6s1.local:/mnt/My\\040Drive on /Volumes/My\\040Drive (nfs, nodev, nosuid, soft, mounted by local-user)
    disk7s2-1.local:/mnt/Linux on /Volumes/Linux (nfs, nodev, read-only, soft)
    server.example:/share on /Volumes/Other (nfs, soft)
    """

    let mounts = MountTableParser.parse(output)

    #expect(mounts.count == 3)
    #expect(mounts[0].deviceIdentifier == "disk6s1")
    #expect(mounts[0].mountPoint == "/Volumes/My Drive")
    #expect(mounts[0].isReadOnly == false)
    #expect(mounts[1].deviceIdentifier == "disk7s2")
    #expect(mounts[1].isReadOnly == true)
    #expect(mounts[2].deviceIdentifier == nil)
}

@MainActor
@Test func tableOnlyNtfsmacMountIsInconsistentRatherThanAuthoritativeGreen() async {
    let runner = SnapshotCommandRunner(
        status: CommandResult(output: "", exitCode: 0),
        mount: CommandResult(
            output: "disk6s1.local:/mnt/Media on /Volumes/Media (nfs, soft)",
            exitCode: 0
        )
    )
    let provider = RealMountSnapshotProvider(
        runner: runner,
        anylinuxfsPath: "/test/anylinuxfs",
        mountPath: "/test/mount"
    )

    let snapshot = await provider.snapshot()

    #expect(snapshot.mounts.count == 1)
    #expect(snapshot.isAuthoritative == false)
    #expect(snapshot.warningCode == "MOUNT_STATE_INCONSISTENT")
}

@MainActor
@Test func authoritativeExternalUnmountClearsAStaleGuiRow() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: false
        ),
    ]))
    let appState = AppState()
    let helper = SuccessfulHelper()
    let controller = MountController(
        helper: helper,
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.mount(drive, mountPoint: "/Volumes/Media")
    #expect(appState.state == .mountedReadWrite)

    provider.value = MountSnapshot(mounts: [])
    await controller.reconcile(knownDrives: [drive])

    #expect(helper.unmountCalls == [drive.identifier])
    #expect(controller.mountedDrives.isEmpty)
    #expect(appState.state == .idle)
}

@MainActor
@Test func pollingCannotPublishIdleWhileAHelperMountIsStillRunning() async throws {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: []))
    let appState = AppState()
    let controller = MountController(
        helper: DelayedMountHelper(),
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )

    let mountTask = Task { await controller.mount(drive) }
    try await Task.sleep(for: .milliseconds(25))
    #expect(appState.state == .mounting)

    await controller.reconcile(knownDrives: [drive])
    #expect(appState.state == .mounting)

    await mountTask.value
    #expect(appState.state == .error)
    #expect(controller.errorMessage == "mount failed after delay")
}

@MainActor
@Test func finderUnmountRequiresRepeatedInconsistentProofBeforeSessionCleanup() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: false
        ),
    ]))
    let helper = SuccessfulHelper()
    let appState = AppState()
    let controller = MountController(
        helper: helper,
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.mount(drive, mountPoint: "/Volumes/Media")

    provider.value = MountSnapshot(
        mounts: [ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: nil
        )],
        isAuthoritative: false,
        warningCode: "MOUNT_STATE_INCONSISTENT"
    )

    await controller.reconcile(knownDrives: [drive])
    #expect(helper.unmountCalls.isEmpty)
    #expect(appState.state == .mountedUnknown)

    await controller.reconcile(knownDrives: [drive])
    #expect(helper.unmountCalls == [drive.identifier])
    #expect(appState.state == .mountedUnknown)

    provider.value = MountSnapshot(mounts: [])
    await controller.reconcile(knownDrives: [drive])
    #expect(controller.mountedDrives.isEmpty)
    #expect(appState.state == .idle)
}

@MainActor
@Test func failedExternalUnmountCleanupCannotFallBackToIdle() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: false
        ),
    ]))
    let helper = SuccessfulHelper()
    helper.unmountResult = CommandResult(output: "failed", exitCode: 1)
    let appState = AppState()
    let controller = MountController(
        helper: helper,
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.mount(drive, mountPoint: "/Volumes/Media")

    provider.value = MountSnapshot(mounts: [])
    await controller.reconcile(knownDrives: [drive])

    #expect(helper.unmountCalls == [drive.identifier])
    #expect(controller.mountedDrives.isEmpty)
    #expect(appState.state == .error)
    #expect(controller.errorMessage?.hasPrefix("EXTERNAL_UNMOUNT_CLEANUP_UNPROVEN") == true)
    #expect(controller.reconciliationWarning == controller.errorMessage)
}

@MainActor
@Test func cliCreatedMountAppearsWithoutAGuiMountAction() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: false
        ),
    ]))
    let appState = AppState()
    let controller = MountController(
        helper: SuccessfulHelper(),
        snapshotProvider: provider,
        appState: appState
    )

    await controller.reconcile(knownDrives: [drive])

    #expect(controller.mountedDrive == drive)
    #expect(controller.mountedMountPoint == "/Volumes/Media")
    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func unavailableSnapshotPreservesRowsButRemovesTheFalseGreenState() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(
            deviceIdentifier: drive.identifier,
            mountPoint: "/Volumes/Media",
            fsDriver: "ntfs-3g",
            isReadOnly: false
        ),
    ]))
    let appState = AppState()
    let controller = MountController(
        helper: SuccessfulHelper(),
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.mount(drive, mountPoint: "/Volumes/Media")

    provider.value = MountSnapshot(
        mounts: [],
        isAuthoritative: false,
        warningCode: "MOUNT_STATE_SOURCE_UNAVAILABLE"
    )
    await controller.reconcile(knownDrives: [drive])

    #expect(controller.mountedDrive == drive)
    #expect(controller.mountedDrives.first?.isVerified == false)
    #expect(appState.state == .mountedUnknown)
    #expect(controller.reconciliationWarning?.hasPrefix("MOUNT_STATE_SOURCE_UNAVAILABLE") == true)
}

@MainActor
@Test func unavailableSnapshotDoesNotWarnWhenThereIsNoMountClaimToVerify() async {
    let provider = MutableSnapshotProvider(MountSnapshot(
        mounts: [],
        isAuthoritative: false,
        warningCode: "MOUNT_STATE_SOURCE_UNAVAILABLE"
    ))
    let appState = AppState()
    let controller = MountController(
        helper: SuccessfulHelper(),
        snapshotProvider: provider,
        appState: appState
    )

    await controller.reconcile(knownDrives: [])

    #expect(controller.mountedDrives.isEmpty)
    #expect(controller.reconciliationWarning == nil)
    #expect(appState.state == .idle)
}

@MainActor
@Test func oneDisappearingMountDoesNotEraseTheSurvivingMount() async {
    let first = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let second = Drive(identifier: "disk7s2", fsType: "ext4", label: "Linux", size: "32 GB")
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [
        ObservedMount(deviceIdentifier: first.identifier, mountPoint: "/Volumes/Media", fsDriver: "ntfs-3g", isReadOnly: false),
        ObservedMount(deviceIdentifier: second.identifier, mountPoint: "/Volumes/Linux", fsDriver: "ext4", isReadOnly: false),
    ]))
    let appState = AppState()
    let controller = MountController(
        helper: SuccessfulHelper(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.reconcile(knownDrives: [first, second])

    provider.value = MountSnapshot(mounts: [
        ObservedMount(deviceIdentifier: second.identifier, mountPoint: "/Volumes/Linux", fsDriver: "ext4", isReadOnly: false),
    ])
    await controller.reconcile(knownDrives: [first, second])

    #expect(controller.mountedDriveIDs == Set([second.identifier]))
    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func successfulUnmountResponseCannotHideAStillObservedMount() async {
    let drive = Drive(identifier: "disk6s1", fsType: "ntfs", label: "Media", size: "120 GB")
    let observed = ObservedMount(
        deviceIdentifier: drive.identifier,
        mountPoint: "/Volumes/Media",
        fsDriver: "ntfs-3g",
        isReadOnly: false
    )
    let provider = MutableSnapshotProvider(MountSnapshot(mounts: [observed]))
    let helper = SuccessfulHelper()
    let appState = AppState()
    let controller = MountController(
        helper: helper,
        readOnlyChecker: AlwaysReadWrite(),
        snapshotProvider: provider,
        appState: appState
    )
    await controller.mount(drive, mountPoint: "/Volumes/Media")

    await controller.unmount(driveID: drive.identifier)

    #expect(helper.unmountCalls == [drive.identifier])
    #expect(controller.mountedDrive == drive)
    #expect(appState.state == .mountedUnknown)
    #expect(controller.reconciliationWarning?.hasPrefix("UNMOUNT_NOT_OBSERVED") == true)
}
