import Testing
import HelperShared
@testable import NtfsmacGUI

// GUI-PLAN.md "Popover — idle"/"Popover — mounted": [Mount]/Unmount always route through the XPC
// helper (L5), never a shell-out. `FakeHelper` stands in for `HelperClient` (a concrete class
// wrapping a real `NSXPCConnection` — can't be unit tested directly) via the `HelperMounting` seam.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeHelper: HelperMounting, MountSnapshotProviding {
    private(set) var mountCalls: [(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool)] = []
    private(set) var lastRecoveryKey: String?
    private(set) var unmountCalls: [String] = []
    var mountResult: Result<CommandResult, Error> = .success(CommandResult(output: "mounted", exitCode: 0))
    var unmountResult: Result<CommandResult, Error> = .success(CommandResult(output: "unmounted", exitCode: 0))
    var snapshotReadOnlyOverride: Bool?

    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool, recoveryKey: String?) async throws -> CommandResult {
        lastRecoveryKey = recoveryKey
        mountCalls.append((device, driver, mountPoint, readOnly))
        return try mountResult.get()
    }

    func unmount(target: String) async throws -> CommandResult {
        unmountCalls.append(target)
        return try unmountResult.get()
    }

    func snapshot() async -> MountSnapshot {
        let unmounted = Set(unmountCalls)
        var latest: [String: (device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool)] = [:]
        for call in mountCalls where !unmounted.contains(call.device) {
            latest[call.device] = call
        }
        let mounts = latest.values.map { call in
            ObservedMount(
                deviceIdentifier: call.device,
                mountPoint: call.mountPoint ?? "/Volumes/\(call.device)",
                fsDriver: call.driver.rawValue,
                isReadOnly: snapshotReadOnlyOverride ?? call.readOnly
            )
        }.sorted { $0.deviceIdentifier < $1.deviceIdentifier }
        return MountSnapshot(mounts: mounts)
    }
}

@MainActor
@Test func bitLockerRecoveryKeyIsThreadedToTheHelper() async {
    let fake = FakeHelper()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: AppState())
    let drive = Drive(identifier: "disk6s1", fsType: "BitLocker", label: "Encrypted", size: "64.0 GB")

    await controller.mount(drive, recoveryKey: "111111-222222-333333-444444-555555-666666-777777-888888")

    #expect(fake.lastRecoveryKey == "111111-222222-333333-444444-555555-666666-777777-888888")
}

private struct FakeReadOnlyChecker: MountReadOnlyChecking {
    let isReadOnly: Bool
    func isAnyNfsMountReadOnly() async -> Bool { isReadOnly }
}

@MainActor
@Test func mountRoutesThroughHelperAndTransitionsToMountedReadWrite() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive)

    #expect(fake.mountCalls.count == 1)
    #expect(fake.mountCalls[0].device == "disk4s2")
    #expect(fake.mountCalls[0].driver == .ntfs3g)
    #expect(appState.state == .mountedReadWrite)
    #expect(controller.mountedDrive == sampleDrive)
    #expect(controller.errorMessage == nil)
}

@MainActor
@Test func mountThreadsRequestedMountPointAndReadOnlyThroughToHelper() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive, mountPoint: "/Volumes/My Drive", readOnly: true)

    #expect(fake.mountCalls.count == 1)
    #expect(fake.mountCalls[0].mountPoint == "/Volumes/My Drive")
    #expect(fake.mountCalls[0].readOnly == true)
    #expect(controller.mountedMountPoint == "/Volumes/My Drive")
    // Real bug caught by review: this used to report .mountedReadWrite unconditionally,
    // even for a successful read-only-by-request mount.
    #expect(appState.state == .mountedReadOnly)
}

@MainActor
@Test func mountWithoutReadOnlyTransitionsToMountedReadWrite() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive, readOnly: false)

    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func unmountClearsMountedMountPoint() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive, mountPoint: "/Volumes/My Drive")
    await controller.unmount()

    #expect(controller.mountedMountPoint == nil)
}

@MainActor
@Test func mountDerivesExtDriverForExtDriveAndNtfs3gForNtfs() async {
    // The GUI defaults to .ntfs3g; for an ext drive it must instead send .ext so the helper
    // skips --fs-driver and passes --ignore-permissions (all_squash). PopoverContentView calls
    // mount(drive) with no driver, so the controller must derive it from drive.fsType.
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    let extDrive = Drive(identifier: "disk4s1", fsType: "ext", label: "LinuxVol", size: "31.5 GB")
    await controller.mount(extDrive)
    #expect(fake.mountCalls[0].driver == .ext)

    await controller.mount(sampleDrive)
    #expect(fake.mountCalls.last!.driver == .ntfs3g)
}

@MainActor
@Test func unmountRoutesThroughHelperAndTransitionsToIdle() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive)
    await controller.unmount()

    #expect(fake.unmountCalls == ["disk4s2"])
    #expect(appState.state == .idle)
    #expect(controller.mountedDrive == nil)
}

@MainActor
@Test func mountRejectsInvalidDeviceNameWithoutCallingHelper() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let badDrive = Drive(identifier: "not-a-device", fsType: "ntfs", label: "", size: "1.0 GB")

    await controller.mount(badDrive)

    #expect(fake.mountCalls.isEmpty)
    #expect(appState.state == .error)
    #expect(controller.errorMessage != nil)
}

@MainActor
@Test func mountFailureFromHelperTransitionsToError() async {
    let fake = FakeHelper()
    fake.mountResult = .failure(HelperClientError.helper("mount.sh: device busy"))
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive)

    #expect(appState.state == .error)
    #expect(controller.errorMessage == "mount.sh: device busy")
    #expect(controller.mountedDrive == nil)
}

@MainActor
@Test func mountFailureFromNonZeroExitCodeTransitionsToError() async {
    let fake = FakeHelper()
    fake.mountResult = .success(CommandResult(output: "mount.sh: unsupported filesystem", exitCode: 1))
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.mount(sampleDrive)

    #expect(appState.state == .error)
    #expect(controller.errorMessage == "mount.sh: unsupported filesystem")
}

@MainActor
@Test func unmountWithNothingMountedNeverCallsHelper() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    await controller.unmount()

    #expect(fake.unmountCalls.isEmpty)
}

@MainActor
@Test func mountRequestingReadWriteButLandingReadOnlyTransitionsToMountedReadOnlyDirty() async {
    // Root-cause fix: `exitCode == 0` on a `readOnly: false` request doesn't guarantee the
    // mount actually landed read-write — ntfs-3g silently falls back to read-only on a dirty
    // journal. Without checking the real mount options, this was reported as a healthy
    // `.mountedReadWrite` and `.mountedReadOnlyDirty` was unreachable from any real mount.
    let fake = FakeHelper()
    fake.snapshotReadOnlyOverride = true
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: true), appState: appState)

    await controller.mount(sampleDrive, readOnly: false)

    #expect(appState.state == .mountedReadOnlyDirty)
    #expect(controller.mountedDrive == sampleDrive)
}

@MainActor
@Test func mountingASecondDriveWhileOneIsMountedMountsBothDrives() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let otherDrive = Drive(identifier: "disk5s1", fsType: "exfat", label: "Other", size: "64.0 GB")

    await controller.mount(sampleDrive)
    await controller.mount(otherDrive)

    #expect(fake.mountCalls.count == 2)
    #expect(controller.mountedDriveIDs == Set(["disk4s2", "disk5s1"]))
    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func unmountTargetsSpecificDriveAndLeavesOthersMounted() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let otherDrive = Drive(identifier: "disk5s1", fsType: "ext4", label: "ExtVol", size: "32.0 GB")

    await controller.mount(sampleDrive)
    await controller.mount(otherDrive)
    await controller.unmount(driveID: sampleDrive.identifier)

    #expect(fake.unmountCalls == ["disk4s2"])
    #expect(controller.mountedDriveIDs == Set(["disk5s1"]))
    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func unmountingLastDriveReturnsToIdle() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let otherDrive = Drive(identifier: "disk5s1", fsType: "ext4", label: "ExtVol", size: "32.0 GB")

    await controller.mount(sampleDrive)
    await controller.mount(otherDrive)
    await controller.unmount(driveID: sampleDrive.identifier)
    await controller.unmount(driveID: otherDrive.identifier)

    #expect(controller.mountedDriveIDs.isEmpty)
    #expect(appState.state == .idle)
}
