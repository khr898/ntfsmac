import Foundation
import HelperShared

/// One partition `anylinuxfs list` reports as mountable by ntfsmac: NTFS/BitLocker
/// (the existing Windows set) or ext2/3/4. GUI-PLAN.md "Auto-detect compatible drives" —
/// read-only, no privileged call (this unit's Don't clause: listing never goes through the
/// XPC helper).
public struct Drive: Identifiable, Equatable, Sendable {
    /// `diskNsM`, already re-checked against `deviceNamePattern` (L6) at parse time.
    public let identifier: String
    /// Raw fstype anylinuxfs emits: "ntfs" | "BitLocker" (WINDOWS_FS_TYPES) or
    /// "ext" (GPT-name fallback) or "ext2" | "ext3" | "ext4" (blkid fs_type). See `allowedFsTypes` below.
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

/// Parses `anylinuxfs list` text into `Drive` models. There is no `--json` flag on `ListCmd`
/// (confirmed in `cli.rs`, same finding `3-xpc-helper` made for mount/unmount) — the real output
/// is `diskutil list`, augmented in place: `darwin::augment_line` substitutes the TYPE column
/// with the real fs_type and the NAME column with the volume label at fixed widths
/// (`vendor/src/anylinuxfs/anylinuxfs/src/diskutil/{mod,darwin}.rs`). Whole-disk rows (index 0,
/// scheme line) and the header line never end in a `diskNsM` identifier, so anchoring on
/// `validateDevice` for the trailing token naturally excludes them without special-casing.
///
/// The TYPE column is NOT always a single blkid fstype token: for NTFS, blkid's fs_type can be
/// empty, so `augment_line` falls back to the raw partition type. GPT then reports "Microsoft
/// Basic Data", while MBR reports "Windows_NTFS". The regex captures the TYPE+NAME columns as
/// one blob and `deriveFsTypeAndLabel` maps both prefixes to ntfs. Both names are part of the
/// server's WINDOWS_FS_TYPES set. The fstype is display-only — mount validates `--fs-driver`
/// itself, never the picker.
///
/// Scope filter: ntfsmac mounts only NTFS + BitLocker + ext2/3/4 (exFAT is excluded — macOS
/// already reads/writes it natively), so `allowedFsTypes` drops the rest client-side. Mirrors
/// `NTFSMAC_ALLOWED_FS_TYPES` in cli/lib/list-drives.sh — bash and Swift can't share source,
/// two impls kept in sync deliberately.
public enum DriveListParser {
    /// Filesystems ntfsmac mounts: Windows (WINDOWS_FS_TYPES minus exfat — macOS already
    /// reads/writes exFAT) + ext2/3/4 (kernel auto-detect, no --fs-driver). Keep in sync with
    /// `NTFSMAC_ALLOWED_FS_TYPES` in cli/lib/list-drives.sh.
    static let allowedFsTypes: Set<String> = ["ntfs", "BitLocker", "ext", "ext2", "ext3", "ext4"]

    /// Captures the TYPE+NAME columns as one blob (group 1), then size (group 2) and ident
    /// (group 3) from the right. Splitting TYPE from NAME positionally is fragile (both are
    /// multi-word, space-padded to fixed widths) and unnecessary: ident is unambiguous from
    /// the right, and fstype is derived from the blob's prefix by `deriveFsTypeAndLabel`.
    private static let partitionLine = try! NSRegularExpression(
        pattern: #"^\s*\d+:\s+(.+?)\s+(\*?[0-9.]+\s+\S+)\s+(\S+)\s*$"#
    )

    public static func parse(_ output: String) -> [Drive] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> Drive? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = partitionLine.firstMatch(in: line, range: range),
              let blob = capture(match, 1, in: line),
              let size = capture(match, 2, in: line),
              let ident = capture(match, 3, in: line),
              validateDevice(ident)
        else { return nil }

        let (fsType, label) = deriveFsTypeAndLabel(blob)
        guard allowedFsTypes.contains(fsType) else { return nil }
        return Drive(identifier: ident, fsType: fsType, label: label, size: size)
    }

    /// Splits the TYPE+NAME blob into (fstype, label). "Microsoft Basic Data" is the GPT type
    /// for ntfs (and exfat, but exfat is out of scope — when blkid resolves exfat it surfaces as
    /// "exfat" and is dropped by `allowedFsTypes`; the rare GPT-fallback case can't distinguish
    /// ntfs from exfat, same limitation as the server's `--microsoft` filter). "Windows_NTFS"
    /// is the corresponding MBR type emitted by real external disks. Match both as prefixes so
    /// NTFS survives even when blkid's fs_type is empty. "BitLocker" is its own partition type.
    /// Everything else is a blkid single-token fstype (ext2/3/4, sometimes ntfs) plus the label.
    private static func deriveFsTypeAndLabel(_ blob: String) -> (fsType: String, label: String) {
        let trimmed = blob.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Microsoft Basic Data") {
            let label = trimmed.dropFirst("Microsoft Basic Data".count).trimmingCharacters(in: .whitespaces)
            return ("ntfs", label)
        }
        if trimmed.hasPrefix("Windows_NTFS") {
            let label = trimmed.dropFirst("Windows_NTFS".count).trimmingCharacters(in: .whitespaces)
            return ("ntfs", label)
        }
        if trimmed.hasPrefix("BitLocker") {
            let label = trimmed.dropFirst("BitLocker".count).trimmingCharacters(in: .whitespaces)
            return ("BitLocker", label)
        }
        // GPT type name "Linux Filesystem" (GUID 0FC63DAF-...) is what darwin::augment_line falls
        // back to when blkid can't resolve the ext superblock (darwin.rs fs_type.unwrap_or(
        // part_type); the name is in LINUX_PART_TYPES, mod.rs). One GPT type covers ALL ext
        // versions — ext2, ext3, ext4 — Apple diskutil does not distinguish them, so the GPT
        // name can't either. Map to a generic "ext" fstype (kernel auto-detects at mount; no
        // --fs-driver needed). The single-token branch would grab "Linux" and the allow-set
        // would reject the row — the ext equivalent of the NTFS "Microsoft Basic Data" bug.
        if trimmed.hasPrefix("Linux Filesystem") {
            let label = trimmed.dropFirst("Linux Filesystem".count).trimmingCharacters(in: .whitespaces)
            return ("ext", label)
        }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let fsType = parts.isEmpty ? "" : String(parts[0])
        let label = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (fsType, label)
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> String? {
        guard let range = Range(match.range(at: index), in: line) else { return nil }
        return String(line[range])
    }
}

/// Polls `anylinuxfs list` on an interval plus on-demand (Refresh ↻ button,
/// GUI-PLAN.md "Popover — idle"). anylinuxfs 0.18.0 can return no rows for an unfiltered `list`
/// on macOS even though each family-specific probe finds the disk, so production combines
/// `list --microsoft` and `list --linux`. `DriveListParser.allowedFsTypes` then filters to
/// ntfsmac's narrower scope (NTFS-family + ext2/3/4) client-side. Reuses `HelperShared`'s
/// `PrivilegedCommandRunning`/`RealCommandRunner` seam (already used by `HelperService`) instead
/// of a second process-spawn helper — this call itself is unprivileged, only the runner shape
/// is reused. Production scans run away from the main actor because the first VM-backed list can
/// take long enough to make the menu-bar popover appear hung.
@MainActor
public final class DriveScanner: ObservableObject {
    @Published public private(set) var drives: [Drive] = []
    @Published public private(set) var lastError: String?

    // An explicit runner is the deterministic test/demo seam and remains actor-bound because the
    // shared protocol is intentionally not Sendable. Production leaves this nil and creates the
    // concrete value inside the detached operation, so no non-Sendable instance crosses actors.
    private let runner: (any PrivilegedCommandRunning)?
    private let anylinuxfsPath: String
    private let scanTimeout: TimeInterval
    private var pollTask: Task<Void, Never>?

    public init(
        runner: (any PrivilegedCommandRunning)? = nil,
        anylinuxfsPath: String = "\(installPrefix)/bin/anylinuxfs",
        scanTimeout: TimeInterval = 10
    ) {
        self.runner = runner
        self.anylinuxfsPath = anylinuxfsPath
        self.scanTimeout = scanTimeout
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
        let microsoft: CommandResult
        let linux: CommandResult
        if let runner {
            microsoft = runner.run(anylinuxfsPath, ["list", "--microsoft"])
            linux = runner.run(anylinuxfsPath, ["list", "--linux"])
        } else {
            // anylinuxfs enforces a global single-instance lock. Running the two family probes
            // concurrently makes one nondeterministically fail with "another instance is already
            // running"; when the empty Linux probe wins, the GUI incorrectly publishes no drives.
            // Keep both calls off the main actor, but sequence them behind one detached operation.
            (microsoft, linux) = await Self.runBothOffMain(
                anylinuxfsPath,
                timeout: scanTimeout
            )
        }

        let successfulResults = [microsoft, linux].filter { $0.exitCode == 0 }
        if !successfulResults.isEmpty {
            // A future anylinuxfs version may report a partition in both families. Preserve the
            // Microsoft-then-Linux display order while ensuring a stable one-row-per-device list.
            var seenIdentifiers = Set<String>()
            drives = successfulResults
                .flatMap { DriveListParser.parse($0.output) }
                .filter { seenIdentifiers.insert($0.identifier).inserted }
        }

        let failedResults = [microsoft, linux].filter { $0.exitCode != 0 }
        if failedResults.isEmpty {
            lastError = nil
        } else {
            lastError = failedResults
                .map(\.output)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private nonisolated static func runBothOffMain(
        _ executablePath: String,
        timeout: TimeInterval
    ) async -> (CommandResult, CommandResult) {
        await Task.detached(priority: .userInitiated) {
            let runner = RealCommandRunner()
            let microsoft = runner.run(executablePath, ["list", "--microsoft"], timeout: timeout)
            let linux = runner.run(executablePath, ["list", "--linux"], timeout: timeout)
            return (microsoft, linux)
        }.value
    }

    private nonisolated static func runOffMain(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            RealCommandRunner().run(executablePath, arguments, timeout: timeout)
        }.value
    }
}
