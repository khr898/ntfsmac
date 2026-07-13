import Foundation
import HelperShared

/// One partition `anylinuxfs list --microsoft` reports as NTFS/exFAT/BitLocker-compatible.
/// GUI-PLAN.md "Auto-detect compatible drives" — read-only, no privileged call (this unit's
/// Don't clause: listing never goes through the XPC helper).
public struct Drive: Identifiable, Equatable, Sendable {
    /// `diskNsM`, already re-checked against `deviceNamePattern` (L6) at parse time.
    public let identifier: String
    /// Raw value from `WINDOWS_FS_TYPES` (`vendor/.../diskutil/mod.rs`): "ntfs" | "exfat" | "BitLocker".
    public let fsType: String
    /// Volume label; empty when the partition has none.
    public let label: String
    /// Already human-formatted by anylinuxfs, e.g. "500.0 GB" — not re-parsed to bytes.
    public let size: String

    public var id: String { identifier }

    public init(identifier: String, fsType: String, label: String, size: String) {
        self.identifier = identifier
        self.fsType = fsType
        self.label = label
        self.size = size
    }
}

/// Parses `anylinuxfs list --microsoft` text into `Drive` models. There is no `--json` flag on
/// `ListCmd` (confirmed in `cli.rs`, same finding `3-xpc-helper` made for mount/unmount) — the
/// real output is `diskutil list`, augmented in place: `darwin::augment_line` substitutes the
/// TYPE column with the real fs_type and the NAME column with the volume label at fixed widths
/// (`vendor/src/anylinuxfs/anylinuxfs/src/diskutil/{mod,darwin}.rs`). Whole-disk rows (index 0,
/// scheme line) and the header line never end in a `diskNsM` identifier, so anchoring on
/// `validateDevice` for the trailing token naturally excludes them without special-casing.
public enum DriveListParser {
    private static let partitionLine = try! NSRegularExpression(
        pattern: #"^\s*\d+:\s+(\S+)\s+(.+?)\s+(\*?[0-9.]+\s+\S+)\s+(\S+)\s*$"#
    )

    public static func parse(_ output: String) -> [Drive] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> Drive? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = partitionLine.firstMatch(in: line, range: range),
              let fsType = capture(match, 1, in: line),
              let rawLabel = capture(match, 2, in: line),
              let size = capture(match, 3, in: line),
              let ident = capture(match, 4, in: line),
              validateDevice(ident)
        else { return nil }

        return Drive(identifier: ident, fsType: fsType, label: rawLabel.trimmingCharacters(in: .whitespaces), size: size)
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }
}

/// Polls `anylinuxfs list --microsoft` on an interval plus on-demand (Refresh ↻ button,
/// GUI-PLAN.md "Popover — idle"). Reuses `HelperShared`'s `PrivilegedCommandRunning`/
/// `RealCommandRunner` seam (already used by `HelperService`) instead of a second process-spawn
/// helper — this call itself is unprivileged, only the runner shape is reused.
@MainActor
public final class DriveScanner: ObservableObject {
    @Published public private(set) var drives: [Drive] = []
    @Published public private(set) var lastError: String?

    // ponytail: same non-Sendable `any PrivilegedCommandRunning` typing `HelperService` already
    // uses — matches the existing seam instead of adding a `Sendable` conformance to the shared
    // protocol (that's `3-xpc-helper`'s file, out of this unit's scope). Trade-off: `runner.run`
    // blocks this actor for the subprocess's duration; acceptable for a background popover poll,
    // revisit with a detached hop if a slow `anylinuxfs list` is ever felt in the UI.
    private let runner: any PrivilegedCommandRunning
    private let anylinuxfsPath: String
    private var pollTask: Task<Void, Never>?

    public init(
        runner: any PrivilegedCommandRunning = RealCommandRunner(),
        anylinuxfsPath: String = "\(installPrefix)/bin/anylinuxfs"
    ) {
        self.runner = runner
        self.anylinuxfsPath = anylinuxfsPath
    }

    deinit {
        pollTask?.cancel()
    }

    /// ponytail: fixed 5s poll, no backoff/jitter — add a `3-preferences` knob if a real drive
    /// swap ever needs to show up faster, or if this proves too chatty against `anylinuxfs`.
    public func startPolling(interval: Duration = .seconds(5)) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func refresh() async {
        let result = runner.run(anylinuxfsPath, ["list", "--microsoft"])

        if result.exitCode == 0 {
            drives = DriveListParser.parse(result.output)
            lastError = nil
        } else {
            lastError = result.output
        }
    }
}
