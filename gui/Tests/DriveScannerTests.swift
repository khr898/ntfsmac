import Foundation
import Testing
import HelperShared
@testable import NtfsmacGUI

// GUI-PLAN.md "Auto-detect compatible drives" — real `anylinuxfs list --microsoft` output shape:
// `diskutil list`, augmented in place (TYPE/NAME columns swapped for real fs_type/label at fixed
// widths, `vendor/src/anylinuxfs/anylinuxfs/src/diskutil/{mod,darwin}.rs`). Samples below are
// hand-built to match that real column layout, not fabricated JSON.

private let sampleListOutput = """
/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk4
   1:                       ntfs My Drive                500.0 GB   disk4s2
"""

private let sampleMultiDiskOutput = """
/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk4
   1:                       ntfs My Drive                500.0 GB   disk4s2

/dev/disk5 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:  FDisk_partition_scheme                            *64.0 GB    disk5
   1:                      exfat                          64.0 GB    disk5s1
"""

@Test func parsesNtfsPartitionSkippingHeaderAndWholeDiskRows() {
    let drives = DriveListParser.parse(sampleListOutput)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4s2")
    #expect(drives[0].fsType == "ntfs")
    #expect(drives[0].label == "My Drive")
    #expect(drives[0].size == "500.0 GB")
}

@Test func parsesMultipleDisksButExcludesExfatAlreadySupportedByMacOS() {
    // macOS reads/writes exFAT natively, so ntfsmac must NOT surface exfat partitions —
    // only NTFS (needs write help) + ext (unsupported by macOS) + BitLocker are in scope.
    // The exfat partition in the multi-disk fixture must be filtered client-side.
    let drives = DriveListParser.parse(sampleMultiDiskOutput)
    #expect(drives.count == 1)
    #expect(drives.map(\.identifier) == ["disk4s2"])
    #expect(drives.allSatisfy { $0.fsType != "exfat" })
}

@Test func emptyOutputYieldsNoDrives() {
    #expect(DriveListParser.parse("").isEmpty)
}

@Test func malformedLinesAreSkippedNotCrashed() {
    let garbage = "this is not a diskutil line at all\n???\n\t\n"
    #expect(DriveListParser.parse(garbage).isEmpty)
}

@Test func rejectsPartitionSchemeHeaderOnRowZero() {
    // A whole-disk partition scheme line (e.g. GUID_partition_scheme) must never parse as a mountable drive.
    let wholeDiskOnly = "   0:      GUID_partition_scheme                        *500.1 GB   disk4"
    #expect(DriveListParser.parse(wholeDiskOnly).isEmpty)
}

@Test func parsesUnpartitionedWholeDiskBitLocker() {
    let unpartitioned = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:                  BitLocker                        *16.1 GB    disk4
    """
    let drives = DriveListParser.parse(unpartitioned)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4")
    #expect(drives[0].fsType == "BitLocker")
    #expect(drives[0].label == "")
    #expect(drives[0].size == "16.1 GB")
}

@Test func parsesUnpartitionedWholeDiskNtfs() {
    let unpartitioned = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:                       ntfs FlashDrive             *16.1 GB    disk4
    """
    let drives = DriveListParser.parse(unpartitioned)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4")
    #expect(drives[0].fsType == "ntfs")
    #expect(drives[0].label == "FlashDrive")
    #expect(drives[0].size == "16.1 GB")
}

@Test func parsesUnpartitionedWholeDiskBitLockerWithTouchingAsterisk() {
    let line = "   0:                  BitLocker SECUREDRIVE USB ...*16.1 GB    disk4"
    let drives = DriveListParser.parse(line)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4")
    #expect(drives[0].fsType == "BitLocker")
    #expect(drives[0].label == "SECUREDRIVE USB ...")
    #expect(drives[0].size == "16.1 GB")
}

@Test func parsesUnpartitionedWholeDiskNtfsWithTouchingAsterisk() {
    let line = "   0:               Windows_NTFS A Very Long Volume Labe...*16.1 GB    disk4"
    let drives = DriveListParser.parse(line)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4")
    #expect(drives[0].fsType == "ntfs")
    #expect(drives[0].label == "A Very Long Volume Labe...")
    #expect(drives[0].size == "16.1 GB")
}

@MainActor
@Test func driveListViewShowsEmptyPlaceholderWhenNoDrivesDetected() {
    // Acceptance: "render idle cleanly when empty" — DriveListView must not crash/hang on [].
    let view = DriveListView(drives: [])
    #expect(view.drives.isEmpty)
}

// ext2/3/4 list support — combine the family-specific anylinuxfs probes and retain a client-side
// allow-set {ntfs,BitLocker,ext2,ext3,ext4}.
// Surfaces ext partitions, keeps out-of-scope Linux FS (btrfs/xfs/zfs/LUKS/LVM) hidden. Mirrors
// tests/cli/list-drives.bats — bash and Swift can't share source, two impls kept in sync
// deliberately (per cli/lib/list-drives.sh header comment).

private let sampleExtOutput = """
/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk4
   1:                       ntfs My Drive                500.0 GB   disk4s2
   2:                       ext4 LinuxVol                  50.0 GB   disk4s3
   3:                       btrfs BtrVol                   20.0 GB   disk4s4
"""

@Test func parsesExt4PartitionWithCorrectFsType() {
    let drives = DriveListParser.parse(sampleExtOutput)
    let ext4 = drives.first { $0.identifier == "disk4s3" }
    #expect(ext4 != nil)
    #expect(ext4?.fsType == "ext4")
    #expect(ext4?.label == "LinuxVol")
    #expect(ext4?.size == "50.0 GB")
}

@Test func excludesOutOfScopeFilesystemsFromUnfilteredList() {
    // btrfs is NOT in the allow-set — must be dropped client-side once the scanner switches to
    // bare `anylinuxfs list` (which returns all Linux FS types). Currently RED: DriveListParser
    // has no fstype filter, so btrfs (disk4s4) would be surfaced.
    let drives = DriveListParser.parse(sampleExtOutput)
    #expect(drives.map(\.identifier) == ["disk4s2", "disk4s3"])   // ntfs + ext4 only
    #expect(drives.allSatisfy { $0.fsType != "btrfs" })
}

@Test func parsesNtfsWithRealMultiWordMicrosoftBasicDataTypeColumn() {
    // Real anylinuxfs list output for NTFS: blkid fs_type is empty in this build, so
    // darwin::augment_line falls back to the raw GPT type name "Microsoft Basic Data" for the
    // TYPE column (vendor/.../diskutil/darwin.rs: fs_type.unwrap_or(part_type)). A single-token
    // fstype capture grabs only "Microsoft" and the allow-set rejects the row — the regression
    // that dropped NTFS after commit 1be5bf2 removed --microsoft. The filter must match the
    // "Microsoft Basic Data" prefix, exactly what the server's --microsoft filter keys on.
    let realNtfsOutput = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:      GUID_partition_scheme                        *500.1 GB   disk4
       4:       Microsoft Basic Data Media                   224.2 GB   disk4s4
    """
    let drives = DriveListParser.parse(realNtfsOutput)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4s4")
}

@Test func parsesUnlabeledNtfsWithRealMbrWindowsNtfsTypeColumn() {
    // Captured from a real 248 GB external MBR disk. With no blkid fstype/volume label,
    // anylinuxfs preserves diskutil's "Windows_NTFS" partition type. Treating the first token
    // as an allow-listed fstype used to drop this row entirely from the GUI.
    let realMbrNtfsOutput = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:     FDisk_partition_scheme                        *248.0 GB   disk4
       1:               Windows_NTFS                         248.0 GB   disk4s1
    """
    let drives = DriveListParser.parse(realMbrNtfsOutput)
    #expect(drives == [Drive(identifier: "disk4s1", fsType: "ntfs", label: "", size: "248.0 GB")])
}

@Test func parsesLabeledNtfsWithRealMbrWindowsNtfsTypeColumn() {
    // Captured from a second real MBR USB stick. Text after the partition-type prefix is the
    // volume label and must remain visible to the picker.
    let realMbrNtfsOutput = """
    /dev/disk5 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:     FDisk_partition_scheme                        *8.1 GB     disk5
       1:               Windows_NTFS USB_8GB                 8.1 GB     disk5s1
    """
    let drives = DriveListParser.parse(realMbrNtfsOutput)
    #expect(drives == [Drive(identifier: "disk5s1", fsType: "ntfs", label: "USB_8GB", size: "8.1 GB")])
}

@Test func parsesExtWithRealLinuxFilesystemTypeColumn() {
    // Real anylinuxfs list output for ext when blkid can't resolve the superblock: blkid fs_type
    // is empty, so darwin::augment_line falls back to the raw GPT type name "Linux Filesystem" for
    // the TYPE column (vendor/.../diskutil/darwin.rs: fs_type.unwrap_or(part_type); the GPT name
    // is in LINUX_PART_TYPES, mod.rs:257). The GPT name does NOT distinguish ext2/3/4, so the
    // parser must map the whole "Linux Filesystem" prefix to a generic "ext" fstype — taking the
    // first token "Linux" instead leaves the row rejected by allowedFsTypes. This is the ext
    // equivalent of the NTFS "Microsoft Basic Data" regression above. Fixture is the real
    // output shape from /usr/local/ntfsmac/bin/anylinuxfs list against an ext disk.
    let realExtOutput = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:      GUID_partition_scheme                        *31.5 GB    disk4
       1:                       Linux Filesystem              31.5 GB    disk4s1
    """
    let drives = DriveListParser.parse(realExtOutput)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4s1")
    #expect(drives[0].fsType == "ext")
    #expect(drives[0].label.isEmpty)
    #expect(drives[0].size == "31.5 GB")
}

@Test func parsesExtWithRealLinuxFilesystemTypeColumnAndLabel() {
    // Same GPT-name fallback as above, but the partition carries a volume label in the NAME
    // column. The parser must strip the "Linux Filesystem" prefix and keep the label, not
    // treat "Filesystem" as the label.
    let realExtLabeledOutput = """
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:      GUID_partition_scheme                        *31.5 GB    disk4
       1:                       Linux Filesystem MyVol        31.5 GB    disk4s1
    """
    let drives = DriveListParser.parse(realExtLabeledOutput)
    #expect(drives.count == 1)
    #expect(drives[0].identifier == "disk4s1")
    #expect(drives[0].fsType == "ext")
    #expect(drives[0].label == "MyVol")
}

@MainActor
@Test func driveScannerCombinesMicrosoftAndLinuxProbes() async {
    // Live anylinuxfs 0.18.0 evidence on macOS 26.6.1: bare `list` can return no rows while
    // `--microsoft` finds the connected NTFS disk. Query both mutually-exclusive families so
    // NTFS reliability does not regress while ext partitions remain visible.
    let runner = FakeListRunner()
    let scanner = DriveScanner(runner: runner, anylinuxfsPath: "/stub/anylinuxfs")
    await scanner.refresh()
    // Tuples aren't Equatable; compare element-wise.
    #expect(runner.calls.count == 2)
    #expect(runner.calls[0].path == "/stub/anylinuxfs")
    #expect(runner.calls[0].args == ["list", "--microsoft"])
    #expect(runner.calls[1].path == "/stub/anylinuxfs")
    #expect(runner.calls[1].args == ["list", "--linux"])
    #expect(scanner.drives.map(\.identifier) == ["disk4s2", "disk4s3"])
}

@MainActor
@Test func productionDriveScanDoesNotBlockMainActor() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let probeStarted = tempDirectory.appendingPathComponent("probe-started")
    let releaseProbe = tempDirectory.appendingPathComponent("release-probe")
    let slowList = tempDirectory.appendingPathComponent("slow-list")
    try """
    #!/bin/sh
    : > "\(probeStarted.path)"
    while [ ! -e "\(releaseProbe.path)" ]; do
      sleep 0.01
    done
    exit 0
    """.write(
        to: slowList,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: slowList.path
    )

    let scanner = DriveScanner(anylinuxfsPath: slowList.path, scanTimeout: 2)
    let scanTask = Task { await scanner.refresh() }

    // Wait outside the main actor until the child is running. The child cannot exit until this
    // test resumes on the main actor and writes the release marker. A synchronous production
    // scan would therefore hit DriveScanner's real timeout and fail the assertion below, without
    // relying on a wall-clock scheduling threshold that becomes flaky on a busy CI runner.
    let startedWhileMainActorWasAvailable = await Task.detached {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: probeStarted.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }.value
    #expect(startedWhileMainActorWasAvailable, "the list probe did not start")
    try Data().write(to: releaseProbe)

    await scanTask.value
    #expect(scanner.lastError == nil, "the list probe blocked the main actor until timeout")
}

@MainActor
@Test func productionDriveScanRunsProbesSequentially() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let lockDir = tempDirectory.appendingPathComponent("instance.lock")
    let fakeScript = tempDirectory.appendingPathComponent("fake-anylinuxfs")
    try """
    #!/bin/sh
    if ! mkdir "\(lockDir.path)" 2>/dev/null; then
        echo "another instance is already running" >&2
        exit 1
    fi
    sleep 0.05
    rmdir "\(lockDir.path)"
    cat <<'EOF'
    /dev/disk4 (external, physical):
       #:                       TYPE NAME                    SIZE       IDENTIFIER
       0:      GUID_partition_scheme                        *500.1 GB   disk4
       1:                       ntfs My Drive                500.0 GB   disk4s2
    EOF
    exit 0
    """.write(to: fakeScript, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeScript.path)

    let scanner = DriveScanner(
        anylinuxfsPath: fakeScript.path,
        scanTimeout: 5,
        cacheStateProvider: { .initialized }
    )
    await scanner.refresh()
    #expect(scanner.lastError == nil)
    #expect(scanner.drives.count == 1)
}

@MainActor
@Test func productionDriveScanTerminatesAStalledProbe() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let stalledList = tempDirectory.appendingPathComponent("stalled-list")
    try "#!/bin/sh\nwhile :; do :; done\n".write(
        to: stalledList,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: stalledList.path
    )

    let scanner = DriveScanner(anylinuxfsPath: stalledList.path, scanTimeout: 0.05)
    let clock = ContinuousClock()
    let startedAt = clock.now

    await scanner.refresh()

    #expect(startedAt.duration(to: clock.now) < .seconds(1))
    #expect(scanner.drives.isEmpty)
    #expect(scanner.lastError?.contains("timed out") == true)
}

@MainActor
@Test func driveScannerDetectsUninitializedCacheAndAvoidsParallelRace() async {
    let runner = FakeListRunner()
    var preservedCalled = false
    let scanner = DriveScanner(
        runner: runner,
        anylinuxfsPath: "/stub/anylinuxfs",
        scanTimeout: 10,
        firstRunTimeout: 240,
        cacheStateProvider: { .notInitialized },
        cachePreserver: { preservedCalled = true; return true }
    )
    #expect(!scanner.isInitializingRuntime)
    await scanner.refresh()
    #expect(!scanner.isInitializingRuntime)
    #expect(!preservedCalled)
    // On first run, it must NOT run parallel probes; it must run a single probe to avoid concurrent rootfs writes.
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].path == "/stub/anylinuxfs")
    #expect(runner.calls[0].args == ["list"])
    #expect(!scanner.drives.isEmpty)
}

@MainActor
@Test func driveScannerPreservesIncompleteCacheBeforeScanning() async {
    let runner = FakeListRunner()
    var preservedCalled = false
    var reportedState: AlpineRuntimeCacheState = .incomplete
    let scanner = DriveScanner(
        runner: runner,
        anylinuxfsPath: "/stub/anylinuxfs",
        scanTimeout: 10,
        firstRunTimeout: 240,
        cacheStateProvider: { reportedState },
        cachePreserver: {
            preservedCalled = true
            reportedState = .notInitialized
            return true
        }
    )
    await scanner.refresh()
    #expect(preservedCalled, "DriveScanner should preserve an incomplete cache before attempting to list")
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].args == ["list"])
}

@MainActor
@Test func driveScannerUsesFastDualProbesWhenCacheIsInitialized() async {
    let runner = FakeListRunner()
    var preservedCalled = false
    let scanner = DriveScanner(
        runner: runner,
        anylinuxfsPath: "/stub/anylinuxfs",
        scanTimeout: 10,
        firstRunTimeout: 240,
        cacheStateProvider: { .initialized },
        cachePreserver: { preservedCalled = true; return true }
    )
    await scanner.refresh()
    #expect(!preservedCalled)
    // Initialized cache uses fast dual probes for Microsoft and Linux families
    #expect(runner.calls.count == 2)
    #expect(runner.calls[0].args == ["list", "--microsoft"])
    #expect(runner.calls[1].args == ["list", "--linux"])
}

@MainActor
@Test func driveScannerDeduplicatesConcurrentRefreshCalls() async {
    let runner = FakeSlowRunner(delay: 0.05)
    let scanner = DriveScanner(
        runner: runner,
        anylinuxfsPath: "/stub/anylinuxfs",
        scanTimeout: 10,
        cacheStateProvider: { .initialized }
    )
    async let call1: Void = scanner.refresh()
    async let call2: Void = scanner.refresh()
    async let call3: Void = scanner.refresh()
    _ = await (call1, call2, call3)

    // With single-flight deduplication, only 1 scan pass (2 probes: microsoft & linux) occurred, not 3 duplicate passes (6 probes)
    #expect(runner.calls.count == 2)
}

@MainActor
@Test func driveScannerRetainsSetupTaskAcrossCallerCancellation() async throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: tempDirectory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let probeStarted = tempDirectory.appendingPathComponent("probe-started")
    let releaseProbe = tempDirectory.appendingPathComponent("release-probe")
    let slowList = tempDirectory.appendingPathComponent("slow-list")
    try """
    #!/bin/sh
    : > "\(probeStarted.path)"
    while [ ! -e "\(releaseProbe.path)" ]; do
      sleep 0.01
    done
    echo "\(sampleExtOutput)"
    exit 0
    """.write(
        to: slowList,
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: slowList.path
    )

    let scanner = DriveScanner(
        anylinuxfsPath: slowList.path,
        scanTimeout: 10,
        firstRunTimeout: 240,
        cacheStateProvider: { .notInitialized }
    )

    let callerTask = Task {
        await scanner.refresh()
    }

    // Wait until the detached probe has actually started
    let clock = ContinuousClock()
    let waitStart = clock.now
    while !FileManager.default.fileExists(atPath: probeStarted.path) {
        if clock.now - waitStart > .seconds(2) {
            Issue.record("Probe failed to start within 2s")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(scanner.isInitializingRuntime)

    // Cancel the caller task (simulating the popover closing)
    callerTask.cancel()
    _ = await callerTask.result

    // The background setup task must still be running and isInitializingRuntime must remain true!
    #expect(scanner.isInitializingRuntime)

    // Release the probe to finish
    FileManager.default.createFile(atPath: releaseProbe.path, contents: nil)

    // Await the scanner's completion
    await scanner.waitForCurrentSetup()
    #expect(!scanner.isInitializingRuntime)
    #expect(!scanner.drives.isEmpty)
}

private struct ListCall: Equatable {
    let path: String
    let args: [String]
}

private final class FakeListRunner: PrivilegedCommandRunning {
    private(set) var calls: [ListCall] = []
    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(ListCall(path: executablePath, args: arguments))
        return CommandResult(output: sampleExtOutput, exitCode: 0)
    }
    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

private final class FakeSlowRunner: PrivilegedCommandRunning {
    private(set) var calls: [ListCall] = []
    let delay: TimeInterval
    init(delay: TimeInterval = 0.05) {
        self.delay = delay
    }
    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(ListCall(path: executablePath, args: arguments))
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        return CommandResult(output: sampleExtOutput, exitCode: 0)
    }
    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

private final class FakeDriveListingHelper: DriveListingHelper {
    var stubbedResult = CommandResult(
        output: "   0:                  BitLocker SECUREDRIVE USB ...*16.1 GB    disk4\n",
        exitCode: 0
    )
    var shouldThrow = false
    private(set) var callCount = 0

    func listDrives() async throws -> CommandResult {
        callCount += 1
        if shouldThrow {
            throw NSError(domain: "HelperError", code: 1)
        }
        return stubbedResult
    }
}

@MainActor
@Test func driveScannerUsesPrivilegedHelperWhenAvailable() async {
    let helper = FakeDriveListingHelper()
    let scanner = DriveScanner(helper: helper, cacheStateProvider: { .initialized })
    await scanner.refresh()

    #expect(helper.callCount == 1)
    #expect(scanner.drives.count == 1)
    #expect(scanner.drives[0].identifier == "disk4")
    #expect(scanner.drives[0].fsType == "BitLocker")
    #expect(scanner.drives[0].size == "16.1 GB")
}

@MainActor
@Test func driveScannerFallsBackToRunnerWhenHelperThrows() async {
    let helper = FakeDriveListingHelper()
    helper.shouldThrow = true
    let runner = FakeListRunner()
    let scanner = DriveScanner(runner: runner, helper: helper, anylinuxfsPath: "/stub/anylinuxfs")
    await scanner.refresh()

    #expect(helper.callCount == 1)
    #expect(runner.calls.count == 2)
    #expect(scanner.drives.map(\.identifier) == ["disk4s2", "disk4s3"])
}

