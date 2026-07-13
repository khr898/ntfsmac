import SwiftUI
import AppKit

/// GUI-PLAN.md "Preferences window" table, exactly these five controls (Don't clause: nothing
/// beyond this table). "Reinstall privileged helper" reuses `HelperInstaller.install()` directly
/// — the same path `3-first-run-install` built for first-run, per that unit's own Do clause.
public struct PreferencesView: View {
    @ObservedObject public var settings: Settings
    @ObservedObject public var installer: HelperInstaller
    @ObservedObject public var uninstaller: HelperUninstaller

    @State private var isConfirmingUninstall = false

    public init(settings: Settings, installer: HelperInstaller, uninstaller: HelperUninstaller) {
        self.settings = settings
        self.installer = installer
        self.uninstaller = uninstaller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Launch at login", "Start ntfsmac automatically on login") {
                Toggle("", isOn: $settings.launchAtLogin).labelsHidden()
            }

            row("Show speed in menu bar", "Display live throughput next to the icon") {
                Toggle("", isOn: $settings.showSpeedInMenuBar).labelsHidden()
            }

            Divider()

            row("Reinstall privileged helper", "Repair the SMJobBless XPC helper") {
                HStack(spacing: 6) {
                    if installer.state == .installing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Reinstall…") {
                        Task { await installer.install() }
                    }
                }
            }

            row("Uninstall ntfsmac", uninstallSubtitle) {
                HStack(spacing: 6) {
                    if uninstaller.state == .removingDependencies || uninstaller.state == .removingHelper {
                        ProgressView().controlSize(.small)
                    }
                    Button("Uninstall…", role: .destructive) {
                        isConfirmingUninstall = true
                    }
                    .disabled(uninstaller.state == .removingDependencies || uninstaller.state == .removingHelper)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .windowGlassBackground()
        .confirmationDialog(
            "Uninstall ntfsmac completely?",
            isPresented: $isConfirmingUninstall
        ) {
            Button("Uninstall Everything", role: .destructive) {
                Task { await uninstaller.uninstallEverything() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the CLI, all vendored dependencies, and this privileged helper. After this, dragging ntfsmac.app to the Trash leaves nothing behind. This can't be undone — you'll need to reinstall to use ntfsmac again.")
        }
    }

    private var uninstallSubtitle: String {
        switch uninstaller.state {
        case .idle, .removingDependencies, .removingHelper:
            return "Remove the CLI, dependencies, and this helper — no leftovers"
        case .done:
            return "Uninstalled. Safe to drag ntfsmac.app to the Trash."
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    @ViewBuilder
    private func row<Control: View>(
        _ title: String, _ subtitle: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control()
        }
        .glassCard()
    }

}
