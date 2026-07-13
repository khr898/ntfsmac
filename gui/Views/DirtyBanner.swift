import SwiftUI

/// GUI-PLAN.md "Read-only (dirty) state" table — exact copy, pure predicate. Split from the
/// `View` below the same way `StatusIcon`/`StatusIconView` split (`gui/Status/StatusIcon.swift`)
/// so `DirtyStateTests` can assert visibility without a SwiftUI view-inspection dependency.
public enum DirtyBanner {
    public static let bannerCopy =
        "Mounted read-only — drive has an unclean journal. Eject safely in Windows to enable writing."

    public static let corruptionRiskCopy =
        "Mounting a drive with an unclean journal read/write risks data corruption. Only continue if you understand the risk."

    public static func isVisible(for state: MountState) -> Bool {
        state == .mountedReadOnlyDirty
    }
}

/// Non-dismissable while RO-dirty (this unit's Don't clause: no close control exists here at
/// all). Text-only per `ui/prototype.html`'s warning banner (comp lines 573-579) — the actual
/// "Mount read/write anyway…" action lives on `DriveRow` now (comp puts that button in the
/// drive row's own button stack, not the banner), but the confirmation dialog stays attached
/// here since this is where `remountController`/`drive` are already in scope; `DriveRow`'s
/// button only calls `requestRemount()`, which flips `isConfirmingRemount` and surfaces this
/// dialog (Don't clause: never auto-remount r/w without it).
public struct DirtyBannerView: View {
    @ObservedObject public var appState: AppState
    @ObservedObject public var remountController: RemountController
    public let drive: Drive

    public init(appState: AppState, remountController: RemountController, drive: Drive) {
        self.appState = appState
        self.remountController = remountController
        self.drive = drive
    }

    public var body: some View {
        if DirtyBanner.isVisible(for: appState.state) {
            HStack(alignment: .top, spacing: 9) {
                WarningTriangleGlyph(color: .ntfsYellow)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unclean journal detected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ntfsYellow.opacity(0.9))
                    Text(DirtyBanner.bannerCopy)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.ntfsYellow.opacity(0.62))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ntfsYellow.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.ntfsYellow.opacity(0.22))
            )
            .confirmationDialog(
                "Mount read/write anyway?",
                isPresented: $remountController.isConfirmingRemount
            ) {
                Button("Mount Read/Write", role: .destructive) {
                    Task { await remountController.confirmRemount(drive) }
                }
                Button("Cancel", role: .cancel) {
                    remountController.cancelRemount()
                }
            } message: {
                Text(DirtyBanner.corruptionRiskCopy)
            }
        }
    }
}
