import SwiftUI
import AppKit

/// Assembles GUI-PLAN.md's "Popover — idle" / "Popover — mounted" / "Read-only (dirty) state" /
/// "Error state" tables into the single popover `NtfsmacApp.swift` presents; every subview used
/// here is unmodified, already-reviewed production code — this file only composes them per the
/// state machine `AppState.state` already defines.
/// Header status dot (comp's `dotPulseGreen`/`dotPulseYellow` keyframes) — pulses for every
/// active/mounted state, static for idle/error, same opacity-fade technique `StatusIconView`
/// already uses for the tray icon (no `.symbolEffect`, stays macOS 13.0-compatible).
/// No-drives empty-state copy, extracted as testable constants (same pattern as
/// `DirtyBanner.bannerCopy`) — `PopoverStateRenderTests` renders to an `ImageRenderer` image
/// which can't be grepped for text, so the strings live here for `EmptyStateCopyTests`.
enum EmptyStateCopy {
    static let title = "No NTFS / ext drives connected"
    static let subtitle = "Connect an NTFS or ext drive to\nget started"
}

/// "Other available devices" section copy — the unmounted-drives list shown below the mounted
/// list when one or more drives are already mounted. Says "devices" (not "drives") and only
/// renders once something is primary: before mounting, the detected drives are just "the drives",
/// not "other", so the labeled section is suppressed in the idle state. Mirrors
/// `EmptyStateCopy`'s testable-constant pattern.
enum OtherAvailableCopy {
    static let label = "Other available devices"
}

/// Pure gating decision for the "Other available devices" section, extracted from the view so the
/// idle-vs-mounted behavior is testable without rendering an image. The section (header + small
/// Refresh button) renders whenever a drive is mounted — it must stay visible even when no
/// unmounted drive is currently listed, so the Refresh button stays available to re-scan for
/// newly connected drives without unmounting first. The per-drive rows render only when
/// `rowsRender(availableCount:)` is true (at least one unmounted drive detected).
enum OtherAvailableSection {
    /// Header + Refresh button render iff a drive is mounted (never in the idle state — there the
    /// detected drives are the primary list, not "other").
    static func shouldRender(isMounted: Bool) -> Bool { isMounted }

    /// Per-drive rows render only when at least one unmounted drive is actually available.
    static func rowsRender(availableCount: Int) -> Bool { availableCount > 0 }
}

private struct HeaderStatusDot: View {
    let color: Color
    let isPulsing: Bool
    @State private var isDim = false

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .opacity(isPulsing && isDim ? 0.45 : 1.0)
            .onAppear {
                guard isPulsing else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { isDim = true }
            }
            .accessibilityHidden(true)
    }
}

public struct PopoverContentView: View {
    @ObservedObject public var appState: AppState
    @ObservedObject public var driveScanner: DriveScanner
    @ObservedObject public var mountController: MountController
    @ObservedObject public var throughputMonitor: ThroughputMonitor
    @ObservedObject public var remountController: RemountController
    @ObservedObject public var diagnoseRunner: DiagnoseRunner
    @ObservedObject public var helperInstaller: HelperInstaller
    @ObservedObject public var helperUninstaller: HelperUninstaller
    @ObservedObject public var cliInstallChecker: CLIInstallChecker
    @ObservedObject public var cliAutoStager: CLIAutoStager
    @ObservedObject public var settings: Settings
    @StateObject private var navigation: PopoverNavigation
    public let finderOpener: FinderOpener
    public let helperClient: HelperClient

    @Environment(\.colorScheme) private var colorScheme
    @State private var diagnosePresentation = DiagnosePanelPresentation()
    @State private var securityPresentation = SecurityIndicatorsPresentation()
    @State private var showFDAPrompt = false
    @State private var bitLockerDrive: Drive?
    @State private var bitLockerRecoveryKey = ""

    public init(
        appState: AppState,
        driveScanner: DriveScanner,
        mountController: MountController,
        throughputMonitor: ThroughputMonitor,
        remountController: RemountController,
        diagnoseRunner: DiagnoseRunner,
        helperInstaller: HelperInstaller,
        helperUninstaller: HelperUninstaller,
        cliInstallChecker: CLIInstallChecker,
        cliAutoStager: CLIAutoStager,
        settings: Settings,
        finderOpener: FinderOpener,
        helperClient: HelperClient,
        navigation: PopoverNavigation
    ) {
        self.appState = appState
        self.driveScanner = driveScanner
        self.mountController = mountController
        self.throughputMonitor = throughputMonitor
        self.remountController = remountController
        self.diagnoseRunner = diagnoseRunner
        self.helperInstaller = helperInstaller
        self.helperUninstaller = helperUninstaller
        self.cliInstallChecker = cliInstallChecker
        self.cliAutoStager = cliAutoStager
        self.settings = settings
        self.finderOpener = finderOpener
        self.helperClient = helperClient
        _navigation = StateObject(wrappedValue: navigation)
    }

    /// Source-compatible initializer matching the original public surface. The production app
    /// supplies its long-lived uninstaller/navigation objects through the designated initializer.
    public init(
        appState: AppState,
        driveScanner: DriveScanner,
        mountController: MountController,
        throughputMonitor: ThroughputMonitor,
        remountController: RemountController,
        diagnoseRunner: DiagnoseRunner,
        helperInstaller: HelperInstaller,
        cliInstallChecker: CLIInstallChecker,
        cliAutoStager: CLIAutoStager,
        settings: Settings,
        finderOpener: FinderOpener,
        helperClient: HelperClient
    ) {
        self.init(
            appState: appState,
            driveScanner: driveScanner,
            mountController: mountController,
            throughputMonitor: throughputMonitor,
            remountController: remountController,
            diagnoseRunner: diagnoseRunner,
            helperInstaller: helperInstaller,
            helperUninstaller: HelperUninstaller(),
            cliInstallChecker: cliInstallChecker,
            cliAutoStager: cliAutoStager,
            settings: settings,
            finderOpener: finderOpener,
            helperClient: helperClient,
            navigation: PopoverNavigation()
        )
    }

    public var body: some View {
        Group {
            if navigation.page == .settings {
                PreferencesView(
                    settings: settings,
                    installer: helperInstaller,
                    uninstaller: helperUninstaller,
                    onBack: navigation.showMain
                )
            } else if showFDAPrompt {
                FDAPromptView(
                    onOpenSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                        showFDAPrompt = false
                        mountController.clearError()
                    },
                    onCancel: {
                        showFDAPrompt = false
                        mountController.clearError()
                    }
                )
            // Helper install is a self-contained SMJobBless/XPC flow that doesn't touch the CLI
            // tree at all — gating it behind `cliInstallChecker.isInstalled` would block the
            // "Install Helper…" button while the CLI is still being staged. `CLIAutoStager`
            // stages the CLI (bundled into the .app by `build/package-app.sh`, no tap/Homebrew
            // needed) the moment the helper finishes installing, so helper state is checked
            // first; CLI-missing is the brief, self-clearing window between "helper just
            // installed" and "CLIAutoStager finished running install.sh through it."
            } else if helperInstaller.state != .installed {
                FirstRunView(
                    installer: helperInstaller,
                    diagnoseRunner: diagnoseRunner,
                    onOpenSettings: navigation.showSettings,
                    onQuit: quit
                )
            } else if !cliInstallChecker.isInstalled {
                CLIMissingView(
                    checker: cliInstallChecker,
                    stager: cliAutoStager,
                    onOpenSettings: navigation.showSettings,
                    onQuit: quit
                )
            } else {
                mainContent
            }
        }
        .onChange(of: mountController.errorMessage) { newValue in
            if newValue == "FDA_REQUIRED" {
                showFDAPrompt = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ntfsmacOpenSettings)) { _ in
            navigation.showSettings()
        }
        .task {
            await refreshAll()
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // `ui/prototype.html`'s dirty-journal warning banner sits directly under the header,
            // above the drive row (comp lines 572-581) — was previously rendered after
            // Speed/Security instead, `DirtyBanner.isVisible` still gates it so it's a no-op
            // outside `.mountedReadOnlyDirty`.
            if let mounted = mountController.mountedDrive {
                DirtyBannerView(appState: appState, remountController: remountController, drive: mounted)
            }

            Divider()

            // Mounted drives — one DriveRow per drive, each with its own Unmount pill. Scales to
            // the number of drives anylinuxfs is exporting (one microVM per mount, mixed NTFS+ext).
            if !mountController.mountedDrives.isEmpty {
                ForEach(mountController.mountedDrives) { entry in
                    DriveRow(
                        drive: entry.drive,
                        isMounted: true,
                        isDirty: entry.isDirty,
                        onUnmount: { Task { await mountController.unmount(driveID: entry.id) } },
                        onMountAnyway: { remountController.requestRemount() }
                    )
                }
            }

            // Before anything is mounted: the detected drives are the primary list, not "other" —
            // nothing is primary yet, so no "Other available" section header. Each row is a
            // mountable DriveRow, with a Refresh pill (icon + "Refresh" text, same shape as the
            // no-drives empty-state Refresh) above the list so the user can re-scan before mounting.
            if mountController.mountedDrives.isEmpty && !driveScanner.drives.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        HStack(spacing: 6) {
                            RefreshGlyph()
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(.glassNeutral(colorScheme: colorScheme))
                }
                ForEach(driveScanner.drives) { drive in
                    DriveRow(
                        drive: drive,
                        isMounted: false,
                        onMount: { mountDrive(drive) }
                    )
                }
            }

            // Mounted: the "Other available devices" header + small Refresh button render below the
            // mounted list, above SecurityIndicators — and STAY rendered even when no unmounted
            // drive is currently listed, so the Refresh button stays available to re-scan for newly
            // connected drives. The per-drive rows render only when an unmounted drive is detected.
            if OtherAvailableSection.shouldRender(isMounted: !mountController.mountedDrives.isEmpty) {
                Divider()
                HStack(spacing: 6) {
                    Text(OtherAvailableCopy.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        RefreshGlyph()
                    }
                    .buttonStyle(.glassIcon(colorScheme: colorScheme))
                }
                if OtherAvailableSection.rowsRender(availableCount: otherAvailableDrives.count) {
                    ForEach(otherAvailableDrives) { drive in
                        DriveRow(
                            drive: drive,
                            isMounted: false,
                            onMount: { mountDrive(drive) }
                        )
                    }
                }
            }

            if mountController.mountedDrives.isEmpty && driveScanner.drives.isEmpty {
                emptyState
            }

            if !mountController.mountedDrives.isEmpty {
                Divider()
                // Phase 1 (pf/route hardening) is deferrable/non-blocking (PLAN.md) and
                // `diagnose.sh` doesn't currently surface its state at all
                // (confirmed by `3-security-indicators`) — `.unknown` for both is the only
                // honest value available today, never a fabricated `.enforced`.
                if securityPresentation.isVisible {
                    SecurityIndicatorsView(
                        isolatedNetwork: .unknown,
                        vpnBypass: .unknown,
                        onHide: { securityPresentation.hide() }
                    )
                } else {
                    HiddenSecurityIndicatorsView {
                        securityPresentation.show()
                    }
                }
            }

            if let errorMessage = mountController.errorMessage ?? remountController.errorMessage, errorMessage != "FDA_REQUIRED" {
                Text(errorMessage).font(.caption).foregroundStyle(Color.ntfsRed)
            }

            if let warning = mountController.reconciliationWarning {
                Text(warning).font(.caption).foregroundStyle(Color.ntfsYellow)
            }

            if diagnosePresentation.isVisible {
                DiagnosePanel(runner: diagnoseRunner, mountState: appState.state) {
                    diagnosePresentation.hide()
                }
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        // ponytail: MenuBarExtra(.window) resizes its NSPanel over 2+ layout passes whenever
        // any @Published state here changes — without an explicit vertical fixedSize, the
        // panel briefly converges through a larger intermediate size before settling, which
        // reads as "grow then shrink" on every button tap, not just ones that change content.
        .fixedSize(horizontal: false, vertical: true)
        // MenuBarExtra(.window) does not reliably shrink its NSPanel after a child changes the
        // root view's intrinsic height. Keep credential UI in an overlay: it gets the existing
        // popover's proposal and never participates in layout measurement, so Cancel cannot
        // leave the larger black panel/shadow visible behind the collapsed content.
        .overlay {
            bitLockerUnlockOverlay
        }
    }

    /// `ui/prototype.html`'s popover header (icon-box + title/subtitle + status dot) appears in
    /// every state shown in the comp (mounted lines 113-129, idle 462-477, dirty 555-570) — was
    /// previously just a bare "ntfsmac" headline with no icon, subtitle, or dot at all.
    private var header: some View {
        let style = StatusIcon.style(for: appState.state)
        return HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(style.color.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.color.opacity(0.28)))
                DriveHeaderGlyph(color: style.color)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("ntfsmac").font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HeaderStatusDot(color: style.color, isPulsing: appState.state != .idle && appState.state != .error)
                .help(TooltipCopy.status(for: appState.state))
        }
    }

    /// Drives the scanner sees that aren't currently mounted — the "Other available" section.
    private var otherAvailableDrives: [Drive] {
        driveScanner.drives.filter { !mountController.mountedDriveIDs.contains($0.id) }
    }

    /// Mount an unmounted drive r/w at its default mount point. Shared by the idle primary list
    /// and the mounted "Other available devices" section — both offer the same per-row Mount action.
    private func mountDrive(_ drive: Drive) {
        if drive.fsType.caseInsensitiveCompare("BitLocker") == .orderedSame {
            bitLockerRecoveryKey = ""
            bitLockerDrive = drive
        } else {
            Task { await mountController.mount(drive, mountPoint: nil, readOnly: false) }
        }
    }

    @ViewBuilder
    private var bitLockerUnlockOverlay: some View {
        if let drive = bitLockerDrive ?? driveScanner.drives.first(where: { $0.identifier == mountController.credentialRequiredDeviceID }) {
            ZStack {
                Color.black.opacity(0.18)
                    .contentShape(Rectangle())
                VStack(alignment: .leading, spacing: 10) {
                    Text("Unlock \(drive.label.isEmpty ? drive.identifier : drive.label)")
                        .font(.system(size: 13, weight: .semibold))
                    SecureField("BitLocker password or recovery key", text: $bitLockerRecoveryKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") {
                            bitLockerRecoveryKey = ""
                            bitLockerDrive = nil
                            mountController.dismissCredentialRequest()
                        }
                        Spacer()
                        Button("Unlock & Mount") {
                            let key = bitLockerRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            bitLockerRecoveryKey = ""
                            bitLockerDrive = nil
                            Task { await mountController.mount(drive, mountPoint: nil, readOnly: false, recoveryKey: key) }
                        }
                        .disabled(bitLockerRecoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
                .frame(width: 270)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14))
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func refreshAll() async {
        await driveScanner.refresh()
        await mountController.reconcile(knownDrives: driveScanner.drives)
    }

    private var headerSubtitle: String {
        switch appState.state {
        case .idle:
            driveScanner.drives.isEmpty ? "No drives found" : "\(driveScanner.drives.count) drive(s) detected"
        case .mounting: "Mounting…"
        case .mountedReadWrite: "Mounted read/write"
        case .mountedReadOnly, .mountedReadOnlyDirty: "Mounted read-only"
        case .mountedUnknown: "Mount state needs verification"
        case .error: "Error"
        }
    }

    /// `ui/prototype.html`'s idle empty-state block (comp lines 481-499) — icon + copy + Refresh
    /// pill. Previously missing entirely: `DriveListView` used to render its own plain-text
    /// fallback, but that was dropped when the liquid-glass `DriveRow` rewrite landed, leaving
    /// idle-with-nothing-detected showing nothing above the footer.
    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.12)))
                DriveGlyphEmpty(color: .secondary)
            }
            .frame(width: 44, height: 44)

            VStack(spacing: 4) {
                Text(EmptyStateCopy.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Text(EmptyStateCopy.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await refreshAll() }
            } label: {
                HStack(spacing: 6) {
                    RefreshGlyph()
                    Text("Refresh")
                }
            }
            .buttonStyle(.glassNeutral(colorScheme: colorScheme))
            .help(TooltipCopy.text(for: .refresh))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// `ui/prototype.html`'s footer (comp lines 230-238/504-513/617-626): exactly
    /// `[gear][Diagnose (flex:1)][Quit]` in every non-error state — no Refresh slot here at all
    /// (`DriveScanner` already polls every 5s; the on-demand Refresh pill lives in `emptyState`
    /// only, per GUI-PLAN.md's "Popover — idle" table). Previously this had a 4th SF-Symbol
    /// refresh button in the wrong position, plus SF Symbols instead of the comp's literal glyphs.
    private var footer: some View {
        HStack(spacing: 5) {
            Button {
                navigation.showSettings()
            } label: {
                SettingsGearGlyph(color: .secondary)
            }
            .buttonStyle(.glassIcon(colorScheme: colorScheme))
            .accessibilityLabel("Open Settings")
            .help(TooltipCopy.text(for: .settings))

            Button {
                let mode = DiagnoseActionMode.resolve(
                    commandPressed: NSEvent.modifierFlags.contains(.command)
                )
                diagnosePresentation.show()
                Task {
                    switch mode {
                    case .summary:
                        await diagnoseRunner.run()
                    case .developerJSONExport:
                        if let document = await diagnoseRunner.runForDeveloperExport() {
                            DeveloperDiagnoseSavePanel.present(document: document)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    DiagnoseGlyph()
                    Text("Diagnose")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.glassFooter(colorScheme: colorScheme))
            .disabled(diagnoseRunner.isRunning)
            .help(TooltipCopy.text(for: .diagnose))

            Button {
                quit()
            } label: {
                Text("Quit").frame(height: 28)
            }
            .buttonStyle(.glassFooter(colorScheme: colorScheme))
            .help(TooltipCopy.text(for: .quit))
        }
    }

    // ponytail: throughputMonitor is retained in the init signature (not removed) because
    // dropping it cascades to Package.swift's NtfsmacGUI sources list + ThroughputTests + the
    // app wiring in NtfsmacApp. The Combined speed section it fed was removed per the multi-mount
    // rework; the ThroughputMonitor subsystem is now unused UI-side. Upgrade path: remove the
    // subsystem in one go (Package.swift source + ThroughputTests + this property + init param +
    // NtfsmacApp StateObject + renderPopover helper).

    /// GUI-PLAN.md "Popover — idle": "Quit | Exit app, tear down network state". Clean shutdown
    /// per the maintainer's decision: unmount every active drive → teardown pf/route → ask the
    /// privileged helper to `exit(0)` itself (it's a root launchd on-demand Mach service that
    /// Activity Monitor can't kill without sudo, so it must exit via XPC) → terminate the app.
    /// Best-effort throughout — every step is `try?` so a slow/failed unmount or a helper that's
    /// already gone never blocks quitting. The mount does NOT survive a GUI restart by design.
    private func quit() {
        Task {
            await mountController.unmount()
            _ = try? await helperClient.teardown()
            _ = try? await helperClient.exitHelper()
            NSApp.terminate(nil)
        }
    }
}

enum FDAPromptCopy {
    static let helperServiceName = "com.khr898.ntfsmac.helper"
    static let instructions = "macOS lists ntfsmac Helper under its technical service name, \(helperServiceName), and may show a generic executable icon because the helper is a standalone privileged tool. Enable that exact entry in Full Disk Access. If it is not listed, add it with the '+' button."
}

/// A modal prompt guiding the user to grant Full Disk Access to the privileged helper daemon.
struct FDAPromptView: View {
    let onOpenSettings: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.ntfsYellow.opacity(0.14))
                        .overlay(Circle().strokeBorder(Color.ntfsYellow.opacity(0.3)))
                        .frame(width: 40, height: 40)
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.ntfsYellow)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full Disk Access Required")
                        .font(.system(size: 14, weight: .semibold))
                    Text("ntfsmac needs permission to mount drives.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Text(FDAPromptCopy.instructions)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 8) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))
                
                Spacer()
                
                Button("Open Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.glassPrimary())
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
