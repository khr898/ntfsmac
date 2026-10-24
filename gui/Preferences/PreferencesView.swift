import SwiftUI

/// MenuBarExtra uses a transient window. A native `confirmationDialog` dismisses that window as
/// its destructive button is selected, which made the uninstall action appear to vanish before
/// it reliably reached `HelperUninstaller`. Keep confirmation state in the popover itself instead.
public struct UninstallConfirmationPresentation: Equatable, Sendable {
    public private(set) var isVisible: Bool

    public init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }

    public mutating func request() { isVisible = true }
    public mutating func cancel() { isVisible = false }

    /// Consumes one explicit confirmation. A stale/double action cannot start two uninstalls.
    public mutating func confirm() -> Bool {
        guard isVisible else { return false }
        isVisible = false
        return true
    }
}

/// GUI-PLAN.md "Settings page" table, using the same controls and application-owned state as the
/// former Preferences window. "Reinstall privileged helper" reuses `HelperInstaller.install()`
/// directly — the same path `3-first-run-install` built for first-run, per that unit's Do clause.
public struct PreferencesView: View {
    @ObservedObject public var settings: Settings
    @ObservedObject public var installer: HelperInstaller
    @ObservedObject public var uninstaller: HelperUninstaller
    @ObservedObject public var updater: AppUpdateController
    public var hasActiveMounts: Bool
    public let onBack: (() -> Void)?
    public let productVersion: ProductVersion

    @Environment(\.colorScheme) private var colorScheme
    @State private var uninstallConfirmation: UninstallConfirmationPresentation

    public init(
        settings: Settings,
        installer: HelperInstaller,
        uninstaller: HelperUninstaller,
        updater: AppUpdateController = AppUpdateController(),
        hasActiveMounts: Bool = false,
        onBack: (() -> Void)?
    ) {
        self.init(
            settings: settings,
            installer: installer,
            uninstaller: uninstaller,
            updater: updater,
            hasActiveMounts: hasActiveMounts,
            onBack: onBack,
            productVersion: .current(),
            uninstallConfirmation: .init()
        )
    }

    public init(
        settings: Settings,
        installer: HelperInstaller,
        uninstaller: HelperUninstaller,
        updater: AppUpdateController = AppUpdateController(),
        hasActiveMounts: Bool = false,
        onBack: (() -> Void)?,
        productVersion: ProductVersion
    ) {
        self.init(
            settings: settings,
            installer: installer,
            uninstaller: uninstaller,
            updater: updater,
            hasActiveMounts: hasActiveMounts,
            onBack: onBack,
            productVersion: productVersion,
            uninstallConfirmation: .init()
        )
    }

    init(
        settings: Settings,
        installer: HelperInstaller,
        uninstaller: HelperUninstaller,
        updater: AppUpdateController = AppUpdateController(),
        hasActiveMounts: Bool = false,
        onBack: (() -> Void)?,
        productVersion: ProductVersion,
        uninstallConfirmation: UninstallConfirmationPresentation
    ) {
        self.settings = settings
        self.installer = installer
        self.uninstaller = uninstaller
        self.updater = updater
        self.hasActiveMounts = hasActiveMounts
        self.onBack = onBack
        self.productVersion = productVersion
        _uninstallConfirmation = State(initialValue: uninstallConfirmation)
    }

    public init(
        settings: Settings,
        installer: HelperInstaller,
        uninstaller: HelperUninstaller,
        onBack: (() -> Void)?
    ) {
        self.init(
            settings: settings,
            installer: installer,
            uninstaller: uninstaller,
            updater: AppUpdateController(),
            hasActiveMounts: false,
            onBack: onBack
        )
    }

    public init(
        settings: Settings,
        installer: HelperInstaller,
        uninstaller: HelperUninstaller,
        onBack: (() -> Void)?,
        productVersion: ProductVersion
    ) {
        self.init(
            settings: settings,
            installer: installer,
            uninstaller: uninstaller,
            updater: AppUpdateController(),
            hasActiveMounts: false,
            onBack: onBack,
            productVersion: productVersion
        )
    }

    /// Source-compatible initializer for existing embeddings. The production app always supplies
    /// `onBack` and presents this view inside the menu-bar popover.
    public init(settings: Settings, installer: HelperInstaller, uninstaller: HelperUninstaller) {
        self.init(settings: settings, installer: installer, uninstaller: uninstaller, onBack: nil)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let onBack {
                // ZStack so "Settings" centers over the full popover width — an HStack with two
                // Spacers would center it in the *remaining* space after the Back button, sitting
                // right-of-true-center. The title is the visual anchor; Back is overlaid leading.
                ZStack {
                    VStack(spacing: 1) {
                        Text("Settings")
                            .font(.system(size: 13, weight: .semibold))
                        Text(productVersion.settingsText)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.72))
                            .accessibilityLabel("ntfsmac \(productVersion.settingsText)")
                    }
                    HStack {
                        Button {
                            onBack()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                        .buttonStyle(.glassNeutral(colorScheme: colorScheme))
                        .accessibilityLabel("Back")
                        .help(TooltipCopy.text(for: .back))
                        Spacer()
                    }
                }
                Divider()
            }

            row("Launch at login", launchAtLoginSubtitle) {
                HStack(spacing: 8) {
                    if settings.isUpdatingLaunchAtLogin {
                        ProgressView().controlSize(.small)
                    }
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(settings.isUpdatingLaunchAtLogin)
                    .accessibilityLabel("Launch at login")
                }
            }

            Divider()

            row("Preserve iCloud Private Relay", "Keep Private Relay and VPNs connected during mounts") {
                Toggle(
                    "Preserve iCloud Private Relay",
                    isOn: $settings.preservePrivateRelay
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Preserve iCloud Private Relay")
            }

            Divider()

            row("Network Proxy", networkProxySubtitle) {
                Picker("Network Proxy", selection: $settings.proxyMode) {
                    Text("Direct").tag(ProxyMode.direct)
                    Text("System").tag(ProxyMode.system)
                    Text("Custom").tag(ProxyMode.custom)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Network Proxy")
            }

            if settings.proxyMode == .custom {
                row("Proxy URL", "HTTP, HTTPS, or SOCKS5 address") {
                    TextField("http://127.0.0.1:7890", text: $settings.customProxyURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 140)
                        .accessibilityLabel("Custom Proxy URL")
                }
            }

            Divider()

            row("Reinstall privileged helper", "Repair the SMJobBless XPC helper") {
                HStack(spacing: 6) {
                    if installer.state == .installing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Reinstall…") {
                        Task {
                            await installer.install()
                            if installer.state == .installed {
                                onBack?()
                            }
                        }
                    }
                }
            }

            Divider()

            row(updateTitle, updateSubtitle) {
                updateControl
            }

            row("Uninstall ntfsmac", uninstallSubtitle) {
                HStack(spacing: 6) {
                    if uninstaller.state == .removingDependencies || uninstaller.state == .removingHelper {
                        ProgressView().controlSize(.small)
                    }
                    Button("Uninstall…", role: .destructive) {
                        uninstallConfirmation.request()
                    }
                    .disabled(
                        uninstaller.state == .removingDependencies
                            || uninstaller.state == .removingHelper
                            || isUninstallComplete
                    )
                }
            }

            if uninstallConfirmation.isVisible {
                inlineUninstallConfirmation
            }
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { settings.refreshLaunchAtLoginStatus() }
    }

    private var uninstallSubtitle: String {
        switch uninstaller.state {
        case .idle:
            return "Remove the CLI, dependencies, and this helper — no leftovers"
        case .removingDependencies:
            return "Removing CLI and dependencies…"
        case .removingHelper:
            return "Removing privileged helper…"
        case .done:
            return "Uninstalled. Safe to drag ntfsmac.app to the Trash."
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private var launchAtLoginSubtitle: String {
        settings.launchAtLoginMessage ?? "Start ntfsmac automatically on login"
    }

    private var networkProxySubtitle: String {
        switch settings.proxyMode {
        case .direct:
            return "Direct connection without a proxy"
        case .system:
            if let detected = settings.detectedSystemProxy {
                return "Detected: \(detected)"
            }
            return "No system proxy detected"
        case .custom:
            return "Route microVM through custom proxy"
        }
    }

    private var updateTitle: String {
        switch updater.state {
        case .updateAvailable:
            return "Software Update"
        case .readyToRestart:
            return "Update Ready"
        default:
            return "Software Update"
        }
    }

    private var updateSubtitle: String {
        switch updater.state {
        case .idle:
            return "ntfsmac \(productVersion.settingsText)"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "No new updates"
        case .updateAvailable(let info):
            return "New version available (\(info.version))"
        case .downloading(let progress):
            return "Downloading update… \(Int(progress * 100))%"
        case .extracting:
            return "Verifying update…"
        case .readyToRestart(_, let version):
            if hasActiveMounts {
                return "Please unmount active drives before restarting"
            }
            return "Ready to restart into v\(version)"
        case .failed(let message):
            return "Update failed: \(message)"
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch updater.state {
        case .idle, .upToDate:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates() }
            }

        case .checking, .extracting:
            ProgressView().controlSize(.small)

        case .updateAvailable:
            Button("Download & Install") {
                Task { await updater.downloadAndPrepare() }
            }

        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                    .controlSize(.small)
            }

        case .readyToRestart:
            Button("Restart to Update") {
                updater.restartAndApply(hasActiveMounts: hasActiveMounts)
            }
            .disabled(hasActiveMounts)

        case .failed:
            Button("Retry") {
                Task { await updater.checkForUpdates() }
            }
        }
    }

    /// Inline (in-popover) two-step confirmation — a native `confirmationDialog` would dismiss
    /// MenuBarExtra's transient window before the destructive action reliably reached the helper
    /// (per PR #10). `uninstallConfirmation.confirm()` consumes one explicit tap so a stale/double
    /// action can never start two uninstalls.
    private var inlineUninstallConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Uninstall ntfsmac completely?")
                .font(.system(size: 13, weight: .semibold))
            Text("Removes the CLI, all vendored dependencies, and this privileged helper. Afterward, you can drag ntfsmac.app to the Trash. This can't be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    uninstallConfirmation.cancel()
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))

                Button("Uninstall Everything", role: .destructive) {
                    guard uninstallConfirmation.confirm() else { return }
                    Task { await uninstaller.uninstallEverything() }
                }
                .buttonStyle(.glassDestructive(colorScheme: colorScheme))
            }
        }
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm complete ntfsmac uninstall")
    }

    private var isUninstallComplete: Bool {
        if case .done = uninstaller.state { return true }
        return false
    }

    @ViewBuilder
    private func row<Control: View>(
        _ title: String, _ subtitle: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            control()
        }
        .glassCard()
    }

}
