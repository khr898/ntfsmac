import Testing
import HelperShared
@testable import NtfsmacGUI

// GUI-PLAN.md "Read-only (dirty) state": banner shows only in RO-dirty state, remount is gated
// behind an explicit confirm. `FakeHelper` mirrors `MountControllerTests`' double for the same
// `HelperMounting` seam.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeHelper: HelperMounting {
    private(set) var mountCalls: [String] = []
    var mountResult: Result<CommandResult, Error> = .success(CommandResult(output: "mounted", exitCode: 0))

    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult {
        mountCalls.append(device)
        return try mountResult.get()
    }

    func unmount(target: String) async throws -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

private struct FakeReadOnlyChecker: MountReadOnlyChecking {
    let isReadOnly: Bool
    func isAnyNfsMountReadOnly() async -> Bool { isReadOnly }
}

/// Suspends `mount()` until the test explicitly resumes it — lets a test observe
/// `isRemounting == true` mid-flight, which a fixed-result fake can't do.
private final class BlockingHelper: HelperMounting {
    private(set) var mountCallCount = 0
    private var continuation: CheckedContinuation<CommandResult, Never>?

    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult {
        mountCallCount += 1
        return await withCheckedContinuation { self.continuation = $0 }
    }

    func unmount(target: String) async throws -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }

    func resume(with result: CommandResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@Test func bannerVisibleOnlyInReadOnlyDirtyState() {
    #expect(DirtyBanner.isVisible(for: .mountedReadOnlyDirty))
    #expect(!DirtyBanner.isVisible(for: .idle))
    #expect(!DirtyBanner.isVisible(for: .mounting))
    #expect(!DirtyBanner.isVisible(for: .mountedReadWrite))
    #expect(!DirtyBanner.isVisible(for: .error))
}

@MainActor
@Test func confirmRemountDoesNothingWithoutRequestingFirst() async {
    let fake = FakeHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    // Never called requestRemount() — this is the acceptance criterion itself: "remount is
    // gated behind confirm", so a direct confirmRemount() call must be a no-op.
    await controller.confirmRemount(sampleDrive)

    #expect(fake.mountCalls.isEmpty)
    #expect(appState.state == .mountedReadOnlyDirty)
}

@MainActor
@Test func requestThenConfirmRemountsThroughHelperWhenNoLongerReadOnly() async {
    let fake = FakeHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    controller.requestRemount()
    #expect(controller.isConfirmingRemount)

    await controller.confirmRemount(sampleDrive)

    #expect(fake.mountCalls == ["disk4s2"])
    #expect(!controller.isConfirmingRemount)
    #expect(!controller.isRemounting)
    #expect(appState.state == .mountedReadWrite)
}

@MainActor
@Test func confirmRemountStaysDirtyWhenStillReadOnlyAfterRemount() async {
    // The real safety property this unit exists for: `exitCode == 0` alone must never be
    // reported to the user as a successful read-write remount — verify the live mount options.
    let fake = FakeHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: true), appState: appState)

    controller.requestRemount()
    await controller.confirmRemount(sampleDrive)

    #expect(fake.mountCalls == ["disk4s2"])
    #expect(appState.state == .mountedReadOnlyDirty)
    #expect(controller.errorMessage != nil)
}

@MainActor
@Test func cancelRemountClosesDialogWithoutCallingHelper() async {
    let fake = FakeHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    controller.requestRemount()
    controller.cancelRemount()

    #expect(!controller.isConfirmingRemount)
    #expect(fake.mountCalls.isEmpty)
    #expect(appState.state == .mountedReadOnlyDirty)
}

@MainActor
@Test func confirmRemountRejectsInvalidDeviceWithoutCallingHelper() async {
    let fake = FakeHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)
    let badDrive = Drive(identifier: "not-a-device", fsType: "ntfs", label: "", size: "1.0 GB")

    controller.requestRemount()
    await controller.confirmRemount(badDrive)

    #expect(fake.mountCalls.isEmpty)
    #expect(appState.state == .error)
}

@MainActor
@Test func confirmRemountFailureTransitionsToError() async {
    let fake = FakeHelper()
    fake.mountResult = .success(CommandResult(output: "mount.sh: device busy", exitCode: 1))
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: fake, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    controller.requestRemount()
    await controller.confirmRemount(sampleDrive)

    #expect(appState.state == .error)
    #expect(controller.errorMessage == "mount.sh: device busy")
}

@MainActor
@Test func secondRequestOrConfirmWhileFirstRemountInFlightIsRejected() async {
    let blocking = BlockingHelper()
    let appState = AppState()
    appState.state = .mountedReadOnlyDirty
    let controller = RemountController(helper: blocking, readOnlyChecker: FakeReadOnlyChecker(isReadOnly: false), appState: appState)

    controller.requestRemount()
    let firstAttempt = Task { await controller.confirmRemount(sampleDrive) }
    await Task.yield()
    #expect(controller.isRemounting)

    // The dialog must not reopen, and a direct confirm call must not fire a second privileged
    // mount RPC, while the first attempt is still awaiting the helper.
    controller.requestRemount()
    #expect(!controller.isConfirmingRemount)
    await controller.confirmRemount(sampleDrive)
    #expect(blocking.mountCallCount == 1)

    blocking.resume(with: CommandResult(output: "mounted", exitCode: 0))
    await firstAttempt.value

    #expect(blocking.mountCallCount == 1)
    #expect(!controller.isRemounting)
    #expect(appState.state == .mountedReadWrite)
}
