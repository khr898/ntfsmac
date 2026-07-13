import SwiftUI

/// Shown whenever `CLIInstallChecker.isInstalled` is false — reuses `ui/prototype.html`'s
/// "Error — Helper Missing" visual language (comp lines 636-711: red triangle header, tinted
/// content box, primary action button, footer) for a sibling condition the comp doesn't
/// explicitly draw. This is always transient, self-fixing state, never a "go do something in
/// Terminal" dead end — `CLIAutoStager` already ran (or is about to, via `NtfsmacApp`'s
/// `.task(id: helperInstaller.state)`) the bundled `install.sh` as the already-root privileged
/// helper the moment it installed (`build/package-app.sh` bundles the full CLI/vendored tree into
/// `Contents/Resources/cli-src/` — nothing is staged separately, no tap, no Homebrew). If that
/// automatic attempt failed, the primary action retries the exact same in-app path
/// (`CLIAutoStager.retry()`) and surfaces why it failed — never a CLI/Terminal instruction, since
/// installing the helper is meant to set up the whole backend by itself.
public struct CLIMissingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject public var checker: CLIInstallChecker
    @ObservedObject public var stager: CLIAutoStager
    public let onQuit: () -> Void

    public init(checker: CLIInstallChecker, stager: CLIAutoStager, onQuit: @escaping () -> Void) {
        self.checker = checker
        self.stager = stager
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.ntfsRed.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ntfsRed.opacity(0.28)))
                    ErrorTriangleGlyph(color: .ntfsRed)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text("ntfsmac").font(.system(size: 13, weight: .semibold))
                    Text("Setup required").font(.system(size: 11)).foregroundStyle(Color.ntfsRed.opacity(0.75))
                }
                Spacer()
                Circle().fill(Color.ntfsRed).frame(width: 9, height: 9)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 5) {
                Text("Setup incomplete")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.ntfsRed.opacity(0.95))
                Text(stager.lastFailureReason ?? "Finishing setup automatically — this only takes a moment. If it doesn't clear on its own, click Retry.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.ntfsRed.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.ntfsRed.opacity(0.2)))
            .padding(.horizontal, 10)

            VStack(spacing: 6) {
                Button {
                    Task { await stager.retry() }
                } label: {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))
            }
            .padding(10)

            Divider().padding(.horizontal, 14)

            HStack(spacing: 5) {
                Button {
                    PreferencesOpener.open()
                } label: {
                    SettingsGearGlyph(color: colorScheme == .dark ? .white.opacity(0.52) : .black.opacity(0.45))
                }
                .buttonStyle(.glassIcon(colorScheme: colorScheme))
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.glassFooter(colorScheme: colorScheme, foregroundOpacity: 0.42))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        // `stageIfNeeded()` is idempotent (guarded by `didAttempt`) — safe to call again here in
        // case this view renders before `NtfsmacApp`'s own `.task(id: helperInstaller.state)`
        // attempt has run or landed.
        .task {
            await stager.stageIfNeeded()
            checker.check()
        }
    }
}
