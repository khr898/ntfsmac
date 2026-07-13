import Foundation
import Testing
@testable import NtfsmacGUI
import HelperShared

// GUI-PLAN.md "Popover — mounted": Open in Finder reveals the mount point, enabled only when
// mounted. Acceptance: assert the workspace call target + disabled-when-idle.

private let sampleDrive = Drive(identifier: "disk4s2", fsType: "ntfs", label: "My Drive", size: "500.0 GB")

private final class FakeWorkspace: WorkspaceOpening {
    private(set) var openedPaths: [String] = []
    
    func openPathInFinder(_ path: String) -> Bool {
        openedPaths.append(path)
        return true
    }
}

private final class FakeRunner: PrivilegedCommandRunning {
    var output = ""
    var exitCode: Int32 = 0
    private(set) var calls: [(String, [String])] = []

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append((executablePath, arguments))
        return CommandResult(output: output, exitCode: exitCode)
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

@MainActor
@Test func opensMountPointDerivedFromDriveLabelWhenMountedReadWrite() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    opener.open(sampleDrive, state: .mountedReadWrite)

    #expect(fake.openedPaths == ["/Volumes/My Drive"])
}

@MainActor
@Test func opensMountPointWhenMountedReadOnlyDirty() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    opener.open(sampleDrive, state: .mountedReadOnlyDirty)

    #expect(fake.openedPaths.count == 1)
}

@MainActor
@Test func usesRealMountPointWhenProvidedInsteadOfGuessing() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    opener.open(sampleDrive, state: .mountedReadWrite, mountPoint: "/Volumes/CustomFolder")

    #expect(fake.openedPaths == ["/Volumes/CustomFolder"])
    #expect(runner.calls.isEmpty) // Shouldn't query status if mountPoint is provided
}

@MainActor
@Test func resolvesMountPointDynamicallyFromStatusWhenNull() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    runner.output = "/dev/disk4s2 on /Volumes/DynamicMedia (ntfs-3g, soft)\n/dev/disk5s1 on /Volumes/OtherDrive (exfat)\n"
    let opener = FinderOpener(workspace: fake, runner: runner)

    opener.open(sampleDrive, state: .mountedReadWrite)

    #expect(fake.openedPaths == ["/Volumes/DynamicMedia"])
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].1 == ["status"])
}

@MainActor
@Test func resolvesMountPointFallbackWhenStatusQueryFails() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    runner.exitCode = 1
    let opener = FinderOpener(workspace: fake, runner: runner)

    opener.open(sampleDrive, state: .mountedReadWrite)

    #expect(fake.openedPaths == ["/Volumes/My Drive"])
}

@MainActor
@Test func isEnabledForDeliberateReadOnlyMount() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    #expect(opener.isEnabled(for: .mountedReadOnly))
    opener.open(sampleDrive, state: .mountedReadOnly)

    #expect(fake.openedPaths.count == 1)
}

@MainActor
@Test func fallsBackToIdentifierWhenLabelIsEmpty() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)
    let unlabeled = Drive(identifier: "disk5s1", fsType: "exfat", label: "", size: "1.0 GB")

    opener.open(unlabeled, state: .mountedReadWrite)

    #expect(fake.openedPaths == ["/Volumes/disk5s1"])
}

@MainActor
@Test func disabledWhenIdle() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    #expect(!opener.isEnabled(for: .idle))
    opener.open(sampleDrive, state: .idle)

    #expect(fake.openedPaths.isEmpty)
}

@MainActor
@Test func disabledWhileMountingOrError() {
    let fake = FakeWorkspace()
    let runner = FakeRunner()
    let opener = FinderOpener(workspace: fake, runner: runner)

    #expect(!opener.isEnabled(for: .mounting))
    #expect(!opener.isEnabled(for: .error))
    opener.open(sampleDrive, state: .mounting)
    opener.open(sampleDrive, state: .error)

    #expect(fake.openedPaths.isEmpty)
}
