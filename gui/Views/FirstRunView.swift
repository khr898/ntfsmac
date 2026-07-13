import SwiftUI
import AppKit

/// First-run helper-install prompt (GUI-PLAN.md "App shape": "No windows except Preferences and
/// the first-run helper prompt"). Kicks off `installIfNeeded()` on appear; denial/failure renders
/// `ui/prototype.html`'s "Error — Helper Missing" card (comp lines 636-711) — red icon-box header,
/// message card, primary "Install Helper…" pill, and a footer so Quit/Settings stay reachable even
/// before the helper exists (previously this view had no footer at all — a real dead end).
/// ponytail: the comp's card also shows a separate "Retry" button next to "Diagnose", but this
/// app's `HelperInstaller` only exposes one unconditional `install()` path (Do clause: same path
/// Preferences' "Reinstall…" uses) — a second button calling the identical action would be a fake
/// distinction, so "Install Helper…" is the only action button; "Diagnose" is the other.
public struct FirstRunView: View {
    @ObservedObject public var installer: HelperInstaller
    @ObservedObject public var diagnoseRunner: DiagnoseRunner
    public let onQuit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showDiagnose = false

    public init(installer: HelperInstaller, diagnoseRunner: DiagnoseRunner, onQuit: @escaping () -> Void) {
        self.installer = installer
        self.diagnoseRunner = diagnoseRunner
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch installer.state {
            case .notChecked, .checking:
                ProgressView("Checking privileged helper…")
                    .frame(maxWidth: .infinity)
            case .installing:
                ProgressView("Waiting for authorization…")
                    .frame(maxWidth: .infinity)
            case .installed:
                Label("Privileged helper installed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.ntfsGreen)
            case .denied(let message), .failed(let message):
                errorCard(message: message)
                Button {
                    Task { await installer.install() }
                } label: {
                    HStack(spacing: 6) {
                        InstallHelperGlyph()
                        Text("Install Helper…")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassPrimary())

                Button {
                    showDiagnose = true
                    Task { await diagnoseRunner.run() }
                } label: {
                    HStack(spacing: 5) {
                        DiagnoseGlyph()
                        Text("Diagnose")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))
                .disabled(diagnoseRunner.isRunning)
            }

            if showDiagnose {
                DiagnosePanel(runner: diagnoseRunner)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await installer.installIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(headerColor.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(headerColor.opacity(0.28)))
                ErrorTriangleGlyph(color: headerColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("ntfsmac").font(.system(size: 13, weight: .semibold))
                Text(headerSubtitle).font(.system(size: 11)).foregroundStyle(headerColor.opacity(0.75))
            }
            Spacer()
            Circle().fill(headerColor).frame(width: 9, height: 9)
        }
    }

    private var headerColor: Color {
        switch installer.state {
        case .denied, .failed: .ntfsRed
        case .installed: .ntfsGreen
        case .notChecked, .checking, .installing: .secondary
        }
    }

    private var headerSubtitle: String {
        switch installer.state {
        case .denied, .failed: "Setup required"
        case .installed: "Privileged helper installed"
        case .notChecked, .checking: "Checking privileged helper…"
        case .installing: "Waiting for authorization…"
        }
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Privileged helper not installed")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.ntfsRed.opacity(0.95))
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ntfsRed.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ntfsRed.opacity(0.2)))
    }

    private var footer: some View {
        HStack {
            Button {
                PreferencesOpener.open()
            } label: {
                SettingsGearGlyph(color: .secondary)
            }
            .buttonStyle(.glassIcon(colorScheme: colorScheme))
            Spacer()
            Button(action: onQuit) {
                Text("Quit").frame(height: 28)
            }
            .buttonStyle(.glassFooter(colorScheme: colorScheme))
        }
    }
}
