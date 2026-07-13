import SwiftUI
import AppKit

/// Assembles GUI-PLAN.md's "Popover — idle" / "Popover — mounted" / "Read-only (dirty) state" /
/// "Error state" tables into the single popover `NtfsmacApp.swift` presents; every subview used
/// here is unmodified, already-reviewed production code — this file only composes them per the
/// state machine `AppState.state` already defines.
/// Header status dot (comp's `dotPulseGreen`/`dotPulseYellow` keyframes) — pulses for every
/// active/mounted state, static for idle/error, same opacity-fade technique `StatusIconView`
/// already uses for the tray icon (no `.symbolEffect`, stays macOS 13.0-compatible).
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
    @ObservedObject public var cliInstallChecker: CLIInstallChecker
    @ObservedObject public var cliAutoStager: CLIAutoStager
    @ObservedObject public var settings: Settings
    public let finderOpener: FinderOpener
    public let helperClient: HelperClient

    @Environment(\.colorScheme) private var colorScheme
    @State private var showDiagnose = false
    @State private var showFDAPrompt = false

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
        self.appState = appState
        self.driveScanner = driveScanner
        self.mountController = mountController
        self.throughputMonitor = throughputMonitor
        self.remountController = remountController
        self.diagnoseRunner = diagnoseRunner
        self.helperInstaller = helperInstaller
        self.cliInstallChecker = cliInstallChecker
        self.cliAutoStager = cliAutoStager
        self.settings = settings
        self.finderOpener = finderOpener
        self.helperClient = helperClient
    }

    public var body: some View {
        Group {
            // Helper install is a self-contained SMJobBless/XPC flow that doesn't touch the CLI
            // tree at all — gating it behind `cliInstallChecker.isInstalled` would block the
            // "Install Helper…" button while the CLI is still being staged. `CLIAutoStager`
            // stages the CLI (bundled into the .app by `build/package-app.sh`, no tap/Homebrew
            // needed) the moment the helper finishes installing, so helper state is checked
            // first; CLI-missing is the brief, self-clearing window between "helper just
            // installed" and "CLIAutoStager finished running install.sh through it."
            if helperInstaller.state != .installed {
                // GUI-PLAN.md "App shape": "No windows except Preferences and the first-run
                // helper prompt" — the popover itself gates on the helper being installed first.
                FirstRunView(installer: helperInstaller, diagnoseRunner: diagnoseRunner, onQuit: quit)
            } else if !cliInstallChecker.isInstalled {
                CLIMissingView(checker: cliInstallChecker, stager: cliAutoStager, onQuit: quit)
            } else {
                mainContent
            }
        }
        .task(id: appState.state) { syncThroughputMonitor() }
        .sheet(isPresented: $showFDAPrompt) {
            FDAPromptView(
                onOpenSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                },
                onShowInFinder: {
                    NSWorkspace.shared.selectFile("/Library/PrivilegedHelperTools/com.khr898.ntfsmac.helper", inFileViewerRootedAtPath: "")
                },
                onCancel: {
                    showFDAPrompt = false
                }
            )
        }
        .onChange(of: mountController.errorMessage) { newValue in
            if newValue == "FDA_REQUIRED" {
                showFDAPrompt = true
            }
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

            DriveListView(
                drives: driveScanner.drives,
                mountedDriveID: mountController.mountedDrive?.id,
                isDirty: appState.state == .mountedReadOnlyDirty,
                onMount: { drive in
                    Task {
                        await mountController.mount(
                            drive,
                            mountPoint: nil,
                            readOnly: false
                        )
                    }
                },
                onUnmount: { _ in Task { await mountController.unmount() } },
                onOpenFinder: mountController.mountedDrive.map { mounted in
                    { finderOpener.open(mounted, state: appState.state, mountPoint: mountController.mountedMountPoint) }
                },
                onMountAnyway: { remountController.requestRemount() }
            )

            if mountController.mountedDrive != nil {
                Divider()
                SpeedBar(appState: appState, monitor: throughputMonitor)
                Divider()
                // Phase 1 (pf/route hardening) is deferrable/non-blocking (SHARED_TASK_NOTES.md
                // GATES section) and `diagnose.sh` doesn't currently surface its state at all
                // (confirmed by `3-security-indicators`) — `.unknown` for both is the only
                // honest value available today, never a fabricated `.enforced`.
                SecurityIndicatorsView(isolatedNetwork: .unknown, vpnBypass: .unknown)
            } else if driveScanner.drives.isEmpty {
                emptyState
            }

            if let errorMessage = mountController.errorMessage ?? remountController.errorMessage, errorMessage != "FDA_REQUIRED" {
                Text(errorMessage).font(.caption).foregroundStyle(Color.ntfsRed)
            }

            if showDiagnose {
                DiagnosePanel(runner: diagnoseRunner)
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
        }
    }

    private var headerSubtitle: String {
        switch appState.state {
        case .idle:
            driveScanner.drives.isEmpty ? "No drives found" : "\(driveScanner.drives.count) drive(s) detected"
        case .mounting: "Mounting…"
        case .mountedReadWrite: "Mounted read/write"
        case .mountedReadOnly, .mountedReadOnlyDirty: "Mounted read-only"
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
                Text("No NTFS drives connected").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                Text("Connect an NTFS drive to\nget started")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await driveScanner.refresh() }
            } label: {
                HStack(spacing: 6) {
                    RefreshGlyph()
                    Text("Refresh")
                }
            }
            .buttonStyle(.glassNeutral(colorScheme: colorScheme))
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
                PreferencesOpener.open()
            } label: {
                SettingsGearGlyph(color: .secondary)
            }
            .buttonStyle(.glassIcon(colorScheme: colorScheme))

            Button {
                showDiagnose = true
                Task { await diagnoseRunner.run() }
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

            Button {
                quit()
            } label: {
                Text("Quit").frame(height: 28)
            }
            .buttonStyle(.glassFooter(colorScheme: colorScheme))
        }
    }

    private func syncThroughputMonitor() {
        switch appState.state {
        case .mounting, .mountedReadWrite, .mountedReadOnly, .mountedReadOnlyDirty:
            throughputMonitor.start()
        case .idle, .error:
            throughputMonitor.stop()
        }
    }

    /// GUI-PLAN.md "Popover — idle": "Quit | Exit app, tear down network state". Best-effort —
    /// terminates either way so a slow/failed teardown never blocks quitting.
    private func quit() {
        Task {
            _ = try? await helperClient.teardown()
            NSApp.terminate(nil)
        }
    }
}

/// A beautiful modal prompt guiding the user to grant Full Disk Access to the privileged helper daemon.
struct FDAPromptView: View {
    let onOpenSettings: () -> Void
    let onShowInFinder: () -> Void
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
            
            Text("To proceed, open System Settings and drag the highlighted **com.khr898.ntfsmac.helper** binary from Finder into the Full Disk Access list.")
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
                
                Button("Show in Finder") {
                    onShowInFinder()
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))
                
                Button("Open Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.glassPrimary())
            }
        }
        .padding(20)
        .frame(width: 340)
        .windowGlassBackground()
    }
}

