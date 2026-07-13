import Testing
import HelperShared
@testable import NtfsmacGUI

// GUI-PLAN.md "Popover — idle"/"Popover — mounted": [Mount]/Unmount always route through the XPC
// helper (L5), never a shell-out. `FakeHelper` stands in for `HelperClient` (a concrete class
// wrapping a real `NSXPCConnection` — can't be unit tested directly) via the `HelperMounting` seam.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeHelper: HelperMounting {
    private(set) var mountCalls: [(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool)] = []
    private(set) var unmountCalls: [String] = []
    var mountResult: Result<CommandResult, Error> = .success(CommandResult(output: "mounted", exitCode: 0))
    var unmountResult: Result<CommandResult, Error> = .success(CommandResult(output: "unmounted", exitCode: 0))

    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult {
        mountCalls.append((device, driver, mountPoint, readOnly))
        return try mountResult.get()
    }

    func unmount(target: String) async throws -> CommandResult {
        unmountCalls.append(target)
        return try unmountResult.get()
    }
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
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: true), appState: appState)

    await controller.mount(sampleDrive, readOnly: false)

    #expect(appState.state == .mountedReadOnlyDirty)
    #expect(controller.mountedDrive == sampleDrive)
}

@MainActor
@Test func mountingASecondDriveWhileOneIsMountedIsRejectedWithoutOrphaningTheFirst() async {
    let fake = FakeHelper()
    let appState = AppState()
    let controller = MountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let otherDrive = Drive(identifier: "disk5s1", fsType: "exfat", label: "Other", size: "64.0 GB")

    await controller.mount(sampleDrive)
    await controller.mount(otherDrive)

    #expect(fake.mountCalls.count == 1)
    #expect(controller.mountedDrive == sampleDrive)
    #expect(appState.state == .mountedReadWrite)
}
