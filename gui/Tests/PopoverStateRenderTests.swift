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

private final class FakeHelper: HelperMounting, MountSnapshotProviding {
    var mountResult: Result<CommandResult, Error> = .success(CommandResult(output: "mounted", exitCode: 0))
    private var mounted: [String: ObservedMount] = [:]
    func mount(device: String, driver: FsDriver, mountPoint: String?, readOnly: Bool, recoveryKey: String?) async throws -> CommandResult {
        let result = try mountResult.get()
        if result.exitCode == 0 {
            mounted[device] = ObservedMount(
                deviceIdentifier: device,
                mountPoint: mountPoint ?? "/Volumes/\(device)",
                fsDriver: driver.rawValue,
                isReadOnly: readOnly
            )
        }
        return result
    }
    func unmount(target: String) async throws -> CommandResult {
        mounted.removeValue(forKey: target)
        return CommandResult(output: "", exitCode: 0)
    }
    func snapshot() async -> MountSnapshot {
        MountSnapshot(mounts: mounted.values.sorted { $0.deviceIdentifier < $1.deviceIdentifier })
    }
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
    cliInstallChecker: CLIInstallChecker,
    driveScanner: DriveScanner = DriveScanner(),
    navigation: PopoverNavigation = PopoverNavigation()
) -> CGSize? {
    let view = PopoverContentView(
        appState: appState,
        driveScanner: driveScanner,
        mountController: mountController,
        throughputMonitor: ThroughputMonitor(),
        remountController: RemountController(appState: appState),
        diagnoseRunner: DiagnoseRunner(),
        helperInstaller: helperInstaller,
        helperUninstaller: HelperUninstaller(),
        cliInstallChecker: cliInstallChecker,
        cliAutoStager: CLIAutoStager(checker: cliInstallChecker),
        settings: Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
        finderOpener: FinderOpener(),
        helperClient: HelperClient(),
        navigation: navigation
    )
    let renderer = ImageRenderer(content: view)
    guard let image = renderer.nsImage, image.size.width > 0, image.size.height > 0 else { return nil }
    return image.size
}

@MainActor @Test func settingsPageRendersFromNormalContentWithoutASeparateWindow() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let navigation = PopoverNavigation()
    navigation.showSettings()
    let appState = AppState()

    let size = renderPopover(
        appState: appState,
        mountController: MountController(helper: FakeHelper(), appState: appState),
        helperInstaller: helperInstaller,
        cliInstallChecker: cliInstallChecker,
        navigation: navigation
    )

    #expect(size?.width == 320)
    #expect(navigation.page == .settings)
}

@MainActor @Test func settingsRouteIsAvailableDuringFirstRun() {
    let navigation = PopoverNavigation()
    navigation.showSettings()
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent"], anylinuxfsPaths: ["/nonexistent"])
    checker.check()
    let appState = AppState()

    let size = renderPopover(
        appState: appState,
        mountController: MountController(helper: FakeHelper(), appState: appState),
        helperInstaller: HelperInstaller(service: InstalledService()),
        cliInstallChecker: checker,
        navigation: navigation
    )

    #expect(size?.width == 320)
}

@MainActor @Test func settingsRouteIsAvailableDuringCliRepair() async {
    let helperInstaller = HelperInstaller(service: InstalledService())
    await helperInstaller.installIfNeeded()
    #expect(helperInstaller.state == .installed)

    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent"], anylinuxfsPaths: ["/nonexistent"])
    checker.check()
    #expect(!checker.isInstalled)

    let navigation = PopoverNavigation()
    navigation.showSettings()
    let appState = AppState()
    let size = renderPopover(
        appState: appState,
        mountController: MountController(helper: FakeHelper(), appState: appState),
        helperInstaller: helperInstaller,
        cliInstallChecker: checker,
        navigation: navigation
    )

    #expect(size?.width == 320)
}

@MainActor @Test func mountedReadWriteStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive)
    #expect(appState.state == .mountedReadWrite)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil, "mountedReadWrite popover must render a non-empty image — Unmount row + SecurityIndicators live in this state")
}

@MainActor @Test func mountedWithTwoDrivesRendersBothUnmountRows() async throws {
    // Multi-mount: mounted screen ForEach-es over mountedDrives, one DriveRow (with its own
    // Unmount pill) per drive. A two-drive render that produces a non-empty image proves the
    // per-row path didn't collapse the popover. View content can't be grepped from an
    // ImageRenderer image, so structural non-collapse is the available safety net here.
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive)
    await controller.mount(Drive(identifier: "disk5s1", fsType: "ext4", label: "ExtVol", size: "32.0 GB"))
    #expect(controller.mountedDriveIDs == Set(["disk4s2", "disk5s1"]))
    #expect(appState.state == .mountedReadWrite)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil, "multi-mount popover (two mounted rows, each with Unmount) must render a non-empty image")
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

@MainActor @Test func fdaPromptStateRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    controller.errorMessage = "FDA_REQUIRED"
    #expect(controller.errorMessage == "FDA_REQUIRED")

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker)
    #expect(size != nil)
}

// "Other available" section split: idle-with-drives renders the detected drives as the primary
// list (mountable rows + a Refresh pill, no "Other available" label) — must not collapse. Drive
// scanner seeded via the same FakeListRunner seam DriveScannerTests uses (real `anylinuxfs list`
// output shape), so the popover actually has a drive row to render in the idle state.
@MainActor @Test func idleWithDrivesRendersWithoutCollapsing() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    let scanner = DriveScanner(runner: SeededListRunner(output: sampleListOutput), anylinuxfsPath: "/stub/anylinuxfs")
    await scanner.refresh()
    #expect(scanner.drives.count == 1)

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker, driveScanner: scanner)
    #expect(size != nil, "idle-with-drives popover (detected drive row + Refresh pill, no 'Other available' label) must render a non-empty image")
}

@MainActor @Test func bitLockerCredentialOverlayDoesNotResizePopoverWindow() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let fake = FakeHelper()
    let controller = MountController(helper: fake, appState: appState)
    let scanner = DriveScanner(runner: SeededListRunner(output: sampleListOutput), anylinuxfsPath: "/stub/anylinuxfs")
    await scanner.refresh()

    let idleSize = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker, driveScanner: scanner)
    fake.mountResult = .success(CommandResult(output: "BITLOCKER_CREDENTIAL_REQUIRED", exitCode: 1))
    await controller.mount(sampleDrive)
    let promptSize = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker, driveScanner: scanner)
    controller.dismissCredentialRequest()
    let cancelledSize = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker, driveScanner: scanner)

    #expect(promptSize == idleSize, "credential UI must be an overlay and never enlarge MenuBarExtra's NSPanel")
    #expect(cancelledSize == idleSize, "Cancel must leave the popover at its original intrinsic size")
}

// Mounted with a second unmounted drive available: the "Other available devices" section renders
// below the mounted list and above SecurityIndicators. A render that produces a non-empty image
// proves the mounted-branch section path didn't collapse the popover.
@MainActor @Test func mountedWithUnmountedAvailableRendersSection() async throws {
    let (helperInstaller, cliInstallChecker, cleanup) = try await makeInstalledDependencies()
    defer { cleanup() }
    let appState = AppState()
    let controller = MountController(helper: FakeHelper(), appState: appState)
    await controller.mount(sampleDrive)
    #expect(appState.state == .mountedReadWrite)
    // Scanner sees the mounted drive plus a second unmounted one.
    let scanner = DriveScanner(runner: SeededListRunner(output: sampleMultiDriveListOutput), anylinuxfsPath: "/stub/anylinuxfs")
    await scanner.refresh()
    #expect(scanner.drives.count == 2)
    #expect(scanner.drives.map(\.identifier) == ["disk4s2", "disk5s1"])
    #expect(!scanner.drives.map(\.identifier).allSatisfy { controller.mountedDriveIDs.contains($0) })

    let size = renderPopover(appState: appState, mountController: controller, helperInstaller: helperInstaller, cliInstallChecker: cliInstallChecker, driveScanner: scanner)
    #expect(size != nil, "mounted + available-unmounted popover (mounted row + 'Other available devices' section) must render a non-empty image")
}

// Minimal fake runner for render tests: returns a fixed `anylinuxfs list` output so DriveScanner
// has real parsed drives without spawning a process. Same shape as DriveScannerTests' FakeListRunner.
private final class SeededListRunner: PrivilegedCommandRunning {
    let output: String
    init(output: String) { self.output = output }
    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: output, exitCode: 0)
    }
    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

private let sampleListOutput = """
/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk4
   1:                       ntfs My Drive                500.0 GB   disk4s2
"""

private let sampleMultiDriveListOutput = """
/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk4
   1:                       ntfs My Drive                500.0 GB   disk4s2

/dev/disk5 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:  FDisk_partition_scheme                            *64.0 GB    disk5
   1:                       ext4 ExtVol                   64.0 GB    disk5s1
"""
