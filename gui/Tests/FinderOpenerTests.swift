import Foundation
import Testing
@testable import NtfsmacGUI

// GUI-PLAN.md "Popover — mounted": Open in Finder reveals the mount point, enabled only when
// mounted. Acceptance: assert the workspace call target + disabled-when-idle.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeWorkspace: WorkspaceOpening {
    private(set) var revealedURLs: [URL] = []
    func activateFileViewerSelecting(_ fileURLs: [URL]) {
        revealedURLs.append(contentsOf: fileURLs)
    }
}

@MainActor
@Test func opensMountPointDerivedFromDriveLabelWhenMountedReadWrite() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    opener.open(sampleDrive, state: .mountedReadWrite)

    #expect(fake.revealedURLs == [URL(fileURLWithPath: "/Volumes/My Drive")])
}

@MainActor
@Test func opensMountPointWhenMountedReadOnlyDirty() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    opener.open(sampleDrive, state: .mountedReadOnlyDirty)

    #expect(fake.revealedURLs.count == 1)
}

@MainActor
@Test func usesRealMountPointWhenProvidedInsteadOfGuessing() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    opener.open(sampleDrive, state: .mountedReadWrite, mountPoint: "/Volumes/CustomFolder")

    #expect(fake.revealedURLs == [URL(fileURLWithPath: "/Volumes/CustomFolder")])
}

@MainActor
@Test func isEnabledForDeliberateReadOnlyMount() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    #expect(opener.isEnabled(for: .mountedReadOnly))
    opener.open(sampleDrive, state: .mountedReadOnly)

    #expect(fake.revealedURLs.count == 1)
}

@MainActor
@Test func fallsBackToIdentifierWhenLabelIsEmpty() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)
    let unlabeled = Drive(identifier: "disk5s1", fsType: "exfat", label: "", size: "1.0 GB")

    opener.open(unlabeled, state: .mountedReadWrite)

    #expect(fake.revealedURLs == [URL(fileURLWithPath: "/Volumes/disk5s1")])
}

@MainActor
@Test func disabledWhenIdle() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    #expect(!opener.isEnabled(for: .idle))
    opener.open(sampleDrive, state: .idle)

    #expect(fake.revealedURLs.isEmpty)
}

@MainActor
@Test func disabledWhileMountingOrError() {
    let fake = FakeWorkspace()
    let opener = FinderOpener(workspace: fake)

    #expect(!opener.isEnabled(for: .mounting))
    #expect(!opener.isEnabled(for: .error))
    opener.open(sampleDrive, state: .mounting)
    opener.open(sampleDrive, state: .error)

    #expect(fake.revealedURLs.isEmpty)
}
