import SwiftUI
import NtfsmacGUI

/// Menu-bar agent (LSUIElement=true in Info.plist — no Dock icon, no main window). `MenuBarExtra`
/// (macOS 13+, native) covers the icon+popover shell. Feature content is `PopoverContentView`
/// (`gui/Views/PopoverContentView.swift`), which composes every Phase 3 feature unit into one view.
@main
struct NtfsmacApp: App {
    @StateObject private var appState: AppState
    @StateObject private var driveScanner: DriveScanner
    @StateObject private var mountController: MountController
    @StateObject private var throughputMonitor: ThroughputMonitor
    @StateObject private var remountController: RemountController
    @StateObject private var diagnoseRunner = DiagnoseRunner()
    @StateObject private var helperInstaller: HelperInstaller
    @StateObject private var helperUninstaller: HelperUninstaller
    @StateObject private var cliInstallChecker: CLIInstallChecker
    @StateObject private var settings = Settings()

    private let finderOpener = FinderOpener()
    private let helperClient = HelperClient()
    @StateObject private var cliAutoStager: CLIAutoStager

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)

        // See `DemoScaffold.swift`: inert unless NTFSMAC_UI_DEMO is explicitly set. Real installs
        // never set it, so this branch never runs outside a deliberate live-screen audit.
        if let demoMode = ProcessInfo.processInfo.environment["NTFSMAC_UI_DEMO"] {
            _driveScanner = StateObject(wrappedValue: DemoScaffold.driveScanner())
            _mountController = StateObject(wrappedValue: DemoScaffold.mountController(mode: demoMode, appState: appState))
            _remountController = StateObject(wrappedValue: DemoScaffold.remountController(appState: appState))
            _throughputMonitor = StateObject(wrappedValue: DemoScaffold.throughputMonitor())
        } else {
            _driveScanner = StateObject(wrappedValue: DriveScanner())
            _mountController = StateObject(wrappedValue: MountController(appState: appState))
            _remountController = StateObject(wrappedValue: RemountController(appState: appState))
            _throughputMonitor = StateObject(wrappedValue: ThroughputMonitor())
        }

        // See `DemoScaffold.swift`: separate axis from `NTFSMAC_INSTALL_DEMO` — orthogonal to mount
        // state. Inert unless NTFSMAC_INSTALL_DEMO is explicitly set; real installs never set it.
        let helperInstaller: HelperInstaller
        if let installOutcome = ProcessInfo.processInfo.environment["NTFSMAC_INSTALL_DEMO"] {
            helperInstaller = DemoScaffold.helperInstaller(outcome: installOutcome)
        } else {
            helperInstaller = HelperInstaller()
        }
        _helperInstaller = StateObject(wrappedValue: helperInstaller)

        // `cliAutoStager` needs the *same* `CLIInstallChecker` instance the popover observes, but
        // reading `self.cliInstallChecker` to build it would itself be a `self` read before every
        // stored property (including `cliAutoStager`, which has no default) is assigned — illegal
        // per Swift's struct definite-initialization rule. Using a local, exactly like
        // `appState`/`mountController` above, sidesteps that entirely.
        let cliInstallChecker = CLIInstallChecker()
        _cliInstallChecker = StateObject(wrappedValue: cliInstallChecker)
        _cliAutoStager = StateObject(wrappedValue: CLIAutoStager(checker: cliInstallChecker))

        let helperUninstaller = HelperUninstaller(onUninstallComplete: {
            helperInstaller.reset()
            cliInstallChecker.check()
        })
        _helperUninstaller = StateObject(wrappedValue: helperUninstaller)

        let settings = self.settings
        PreferencesOpener.configure {
            AnyView(PreferencesView(settings: settings, installer: helperInstaller, uninstaller: helperUninstaller))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(
                appState: appState,
                driveScanner: driveScanner,
                mountController: mountController,
                throughputMonitor: throughputMonitor,
                remountController: remountController,
                diagnoseRunner: diagnoseRunner,
                helperInstaller: helperInstaller,
                cliInstallChecker: cliInstallChecker,
                cliAutoStager: cliAutoStager,
                settings: settings,
                finderOpener: finderOpener,
                helperClient: helperClient
            )
            .popoverGlassBackground()
        } label: {
            // `ui/prototype.html`'s red menu-bar icon ("Error — Helper Missing", comp lines
            // 636-657) is driven by the helper install outcome, not `AppState.state` — these were
            // previously fully decoupled, so a denied/failed helper install left the icon grey.
            HStack(spacing: 3) {
                StatusIconView(state: helperInstaller.state.isDeniedOrFailed ? .error : appState.state)
            }
            .task { driveScanner.startPolling() }
            .task(id: helperInstaller.state) {
                if helperInstaller.state == .installing || helperInstaller.state == .notChecked {
                    cliAutoStager.reset()
                }
                guard helperInstaller.state == .installed else { return }
                await cliAutoStager.stageIfNeeded()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
