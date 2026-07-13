import SwiftUI

/// One row per detected drive — `ui/prototype.html`'s "Drive row" comp (mounted/light/dirty
/// variants, lines 134-161/313-339/583-613): icon-box + label/fsType·device + size, then a
/// button row. Not-yet-mounted rows have no comp reference (the comp only shows mounted/idle-
/// empty/dirty/error), so their single `[Mount]` pill is a reasonable extrapolation of the same
/// visual language rather than an invented new one.
public struct DriveRow: View {
    @Environment(\.colorScheme) private var colorScheme
    public let drive: Drive
    public let isMounted: Bool
    public let isDirty: Bool
    public let onMount: () -> Void
    public let onUnmount: () -> Void
    public let onOpenFinder: (() -> Void)?
    public let onMountAnyway: (() -> Void)?

    public init(
        drive: Drive,
        isMounted: Bool = false,
        isDirty: Bool = false,
        onMount: @escaping () -> Void = {},
        onUnmount: @escaping () -> Void = {},
        onOpenFinder: (() -> Void)? = nil,
        onMountAnyway: (() -> Void)? = nil
    ) {
        self.drive = drive
        self.isMounted = isMounted
        self.isDirty = isDirty
        self.onMount = onMount
        self.onUnmount = onUnmount
        self.onOpenFinder = onOpenFinder
        self.onMountAnyway = onMountAnyway
    }

    private var accentColor: Color { isDirty ? .ntfsYellow : .ntfsBlue }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                DriveRowGlyph(color: accentColor)
                    .padding(8.5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accentColor.opacity(isDirty ? 0.1 : 0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(accentColor.opacity(isDirty ? 0.2 : 0.22))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.label.isEmpty ? drive.identifier : drive.label)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(drive.fsType.uppercased()) · /dev/\(drive.identifier)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(drive.size)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isMounted {
                HStack(spacing: 6) {
                    Button {
                        onOpenFinder?()
                    } label: {
                        HStack(spacing: 5) {
                            FinderGlyph()
                            Text("Open in Finder")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassNeutral(colorScheme: colorScheme))

                    Button {
                        onUnmount()
                    } label: {
                        HStack(spacing: 5) {
                            EjectGlyph()
                            Text("Unmount")
                        }
                    }
                    .buttonStyle(.glassDestructive(colorScheme: colorScheme))
                }

                if isDirty, let onMountAnyway {
                    Button {
                        onMountAnyway()
                    } label: {
                        HStack(spacing: 5) {
                            MountAnywayGlyph()
                            Text("Mount read/write anyway…")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassWarning())
                }
            } else {
                Button {
                    onMount()
                } label: {
                    Text("Mount")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassNeutral(colorScheme: colorScheme))
            }
        }
        .padding(.vertical, 2)
    }
}

/// No drive rows to render — `PopoverContentView` shows the comp's rich empty-state block
/// (icon + copy + Refresh) itself when idle with nothing detected; this view only composes the
/// per-drive rows once at least one exists.
public struct DriveListView: View {
    public let drives: [Drive]
    public let mountedDriveID: String?
    public let isDirty: Bool
    public let onMount: (Drive) -> Void
    public let onUnmount: (Drive) -> Void
    public let onOpenFinder: (() -> Void)?
    public let onMountAnyway: (() -> Void)?

    public init(
        drives: [Drive],
        mountedDriveID: String? = nil,
        isDirty: Bool = false,
        onMount: @escaping (Drive) -> Void = { _ in },
        onUnmount: @escaping (Drive) -> Void = { _ in },
        onOpenFinder: (() -> Void)? = nil,
        onMountAnyway: (() -> Void)? = nil
    ) {
        self.drives = drives
        self.mountedDriveID = mountedDriveID
        self.isDirty = isDirty
        self.onMount = onMount
        self.onUnmount = onUnmount
        self.onOpenFinder = onOpenFinder
        self.onMountAnyway = onMountAnyway
    }

    public var body: some View {
        ForEach(drives) { drive in
            DriveRow(
                drive: drive,
                isMounted: drive.id == mountedDriveID,
                isDirty: isDirty && drive.id == mountedDriveID,
                onMount: { onMount(drive) },
                onUnmount: { onUnmount(drive) },
                onOpenFinder: onOpenFinder,
                onMountAnyway: onMountAnyway
            )
        }
    }
}
