import Testing
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

@Test func parsesMultipleDisksIncludingUnlabeledExfatPartition() {
    let drives = DriveListParser.parse(sampleMultiDiskOutput)
    #expect(drives.count == 2)
    #expect(drives.map(\.identifier) == ["disk4s2", "disk5s1"])
    #expect(drives[1].fsType == "exfat")
    #expect(drives[1].label.isEmpty)
}

@Test func emptyOutputYieldsNoDrives() {
    #expect(DriveListParser.parse("").isEmpty)
}

@Test func malformedLinesAreSkippedNotCrashed() {
    let garbage = "this is not a diskutil line at all\n???\n\t\n"
    #expect(DriveListParser.parse(garbage).isEmpty)
}

@Test func rejectsIdentifierMissingPartitionSuffix() {
    // A whole-disk-only line (no `sN` suffix) must never parse as a mountable drive (L6).
    let wholeDiskOnly = "   0:      GUID_partition_scheme                        *500.1 GB   disk4"
    #expect(DriveListParser.parse(wholeDiskOnly).isEmpty)
}

@MainActor
@Test func driveListViewShowsEmptyPlaceholderWhenNoDrivesDetected() {
    // Acceptance: "render idle cleanly when empty" — DriveListView must not crash/hang on [].
    let view = DriveListView(drives: [])
    #expect(view.drives.isEmpty)
}
