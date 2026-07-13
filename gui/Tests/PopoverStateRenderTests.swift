import SwiftUI
import Testing
import HelperShared
@testable import NtfsmacGUI

// GUI-PLAN.md states 5-9 (mounting/mounted rw/ro/dirty/error) can't be walked live on a VM
// without nested-virtualization support (confirmed empirically 2026-07-12: `anylinuxfs shell`
// pulls and unpacks the rootfs correctly, then fails at the actual libkrun VM boot —
// `start vm error: Invalid argument (errno 22)` — a hardware/hypervisor limit, not a bug in this
// app). This file is the structural + wiring substitute the audit still requires: it drives the
// real state machine to each of those states through the exact same fake-helper seams
// `MountControllerTests`/`DirtyStateTests` already use (proven, already-passing coverage — not
// new fakery), then renders the actual `PopoverContentView` via `ImageRenderer` (same technique
// `StatusIconView` already uses to rasterize for the menu bar) and asserts it produced a
// non-trivial image. A render that silently produces a 0×0/nil image would mean the view crashed
// or collapsed to nothing for that state — exactly the class of bug a live walk would have
// caught, caught here instead without a real drive.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeHelper: HelperMounting {
    var mountResult: Result<CommandResult, Error> = .success(CommandResult(output: "mounted", exitCode: 0))
    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool) async throws -> CommandResult {
        try mountResult.get()
    }
    func unmount(target: String) async throws -> CommandResult { CommandResult(output: "", exitCode: 0) }
}

private final class InstalledService: HelperInstallService {
    func isInstalled(label: String) -> Bool { true }
    func bless(label: String) -> HelperInstallOutcome { .installed }
}

@MainActor
private func makeInstalledDependencies() async throws -> (helperInstaller: HelperInstaller, cliInstallChecker: CLIInstallChecker, cleanup: () -> Void) {
    let installer = HelperInstaller(service: InstalledService())
    await installer.installIfNeeded()
    #expect(installer.state == .installed)

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binPath = dir.appendingPathComponent("ntfsmac").path
    FileManager.default.createFile(atPath: binPath, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)
    let checker = CLIInstallChecker(candidatePaths: [binPath], anylinuxfsPaths: [binPath])
    checker.check()
    #expect(checker.isInstalled)

    return (installer, checker, { try? FileManager.default.removeItem(at: dir) })
}

@MainActor
private func renderPopover(
    appState: AppState,
    mountController: MountController,
    helperInstaller: HelperInstaller,
    cliInstallChecker: CLIInstallChecker
) -> CGSize? {
    let view = PopoverContentView(
        appState: appState,
        driveScanner: DriveScanner(),
        mountController: mountController,
        throughputMonitor: ThroughputMonitor(),
        remountController: RemountController(appState: appState),
        diagnoseRunner: DiagnoseRunner(),
        helperInstaller: helperInstaller,
        cliInstallChecker: cliInstallChecker,
        cliAutoStager: CLIAutoStager(checker: cliInstallChecker),
        settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
        finderOpener: FinderOpener(),
        helperClient: HelperClient()
    )
    let renderer = ImageRenderer(content: view)
    guard let image = renderer.nsImage, image.size.width > 0, image.size.height > 0 else { return nil }
    return image.size
}

@MainActor @Test func mountedReadWriteStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive)
    #expect(appState.state == .mountedReadWrite)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil, "mountedReadWrite popover must render a non-empty image — SpeedBar/SecurityIndicators/Unmount row all live in this state")
}

@MainActor @Test func mountedReadOnlyStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive, readOnly: true)
    #expect(appState.state == .mountedReadOnly)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil)
}

@MainActor @Test func mountedReadOnlyDirtyStateRendersDirtyBanner() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive)
    // Matches `DirtyStateTests`' own precedent: dirty detection happens post-mount (real code
    // path in `RemountController`'s remount-completion check), so tests drive to it the same
    // way that code does — `mountedDrive` stays set from the real `mount()` call above.
    appState.state = .mountedReadOnlyDirty
    #expect(controller.mountedDrive == sampleDrive)
    #expect(DirtyBanner.isVisible(for: appState.state))

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil, "dirty-state popover (warning banner + Mount read/write anyway) must render a non-empty image")
}

@MainActor @Test func errorStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let fake = FakeHelper()
    fake.mountResult = .success(CommandResult(output: "mount: device busy", exitCode: 1))
    let controller = MountController(helper: fake, appState: appState)
    await controller.mount(sampleDrive)
    #expect(appState.state == .error)
    #expect(controller.errorMessage != nil)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil, "error-state popover must render the plain-language error message without collapsing")
}

@MainActor @Test func mountingStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    appState.state = .mounting
    let controller = MountController(helper: FakeHelper(), appState: appState)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil)
}
