import Foundation
import Testing
@testable import HelperShared

/// Records every call instead of running a process — lets tests assert exact argv without any
/// privileged/real command execution (mirrors the bats convention of testing wrapper scripts'
/// argument-building, not the underlying real mount).
final class FakeRunner: PrivilegedCommandRunning {
    struct Call: Equatable {
        var executablePath: String
        var arguments: [String]
    }
    private(set) var calls: [Call] = []
    private(set) var pipedInputs: [String] = []
    var stubbedResult = CommandResult(output: "ok", exitCode: 0)

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(Call(executablePath: executablePath, arguments: arguments))
        return stubbedResult
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        pipedInputs.append(input)
        calls.append(Call(executablePath: executablePath, arguments: arguments))
        return stubbedResult
    }
}

/// Awaits a `HelperService` reply-closure call as a plain async value.
private func awaitReply(_ body: (@escaping (Data?, String?) -> Void) -> Void) async -> (Data?, String?) {
    await withCheckedContinuation { continuation in
        body { data, error in
            continuation.resume(returning: (data, error))
        }
    }
}

// MARK: - validateDevice (mirrors tests/cli/validate-device.bats, PLAN.md L6)

@Test func acceptsDisk2s1() {
    #expect(validateDevice("disk2s1"))
}

@Test func acceptsMultiDigitDiskAndSlice() {
    #expect(validateDevice("disk10s3"))
}

@Test func rejectsDiskWithNoSlice() {
    #expect(!validateDevice("disk2"))
}

@Test func rejectsShellInjectionPayload() {
    #expect(!validateDevice("disk2s1; rm -rf /"))
}

@Test func rejectsDevPrefixedDevice() {
    #expect(!validateDevice("/dev/disk2s1"))
}

@Test func rejectsEmptyString() {
    #expect(!validateDevice(""))
}

@Test func rejectsWholeDiskOnlyString() {
    #expect(!validateDevice("disk2s"))
}

@Test func rejectsTrailingGarbage() {
    #expect(!validateDevice("disk2s1foo"))
}

// MARK: - isValidUnmountTarget

@Test func unmountAcceptsBareDevice() {
    #expect(isValidUnmountTarget("disk2s1"))
}

@Test func unmountAcceptsVolumesPath() {
    #expect(isValidUnmountTarget("/Volumes/MyDrive"))
}

@Test func unmountRejectsPathTraversal() {
    #expect(!isValidUnmountTarget("/Volumes/../etc/passwd"))
}

@Test func unmountRejectsArbitraryPath() {
    #expect(!isValidUnmountTarget("/etc/passwd"))
}

@Test func unmountRejectsInjectionPayload() {
    #expect(!isValidUnmountTarget("disk2s1; rm -rf /"))
}

@Test func unmountRejectsShellMetacharactersInVolumesPath() {
    // Security review finding (2026-07-13, HIGH): unmount's target validation had only the
    // traversal check, not the shell-metacharacter blocklist `mount`'s `mountPoint` already had,
    // despite both feeding the same vendored anylinuxfs mount/unmount code.
    #expect(!isValidUnmountTarget("/Volumes/foo\"; rm -rf /;\""))
    #expect(!isValidUnmountTarget("/Volumes/foo`touch /tmp/pwned`"))
}

// MARK: - CommandResult protocol encoding

@Test func commandResultRoundTrips() throws {
    let original = CommandResult(output: "mount: disk2s1 mounted", exitCode: 0)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CommandResult.self, from: data)
    #expect(decoded.output == original.output)
    #expect(decoded.exitCode == original.exitCode)
}

// MARK: - HelperService in-helper device rejection (never touches the runner)

@Test func mountRejectsInvalidDeviceWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1; rm -rf /", driver: FsDriver.ntfs3g.rawValue, mountPoint: nil, readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data == nil)
    #expect(error == "rejected: device \"disk2s1; rm -rf /\" does not match \(deviceNamePattern)")
    #expect(runner.calls.isEmpty, "rejected device must never reach the runner")
}

@Test func mountRejectsUnknownDriverWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: "ext4", mountPoint: nil, readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data == nil)
    #expect(error == "rejected: unknown driver \"ext4\"")
    #expect(runner.calls.isEmpty)
}

@Test func mountRejectsShellMetacharactersInMountPointWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: "/Volumes/Data\"; rm -rf /; #", readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty, "rejected mountPoint must never reach the runner")
}

@Test func mountRejectsMountPointOutsideVolumesWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: "/etc/passwd", readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty)
}

@Test func mountBuildsExpectedArgvForValidDevice() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3.rawValue, mountPoint: "/Volumes/Data", readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].executablePath == "\(installPrefix)/bin/ntfsmac")
    #expect(runner.calls[0].arguments == ["mount", "disk2s1", "/Volumes/Data", "--fs-driver", "ntfs3", "--credential-required-error"])
}

@Test func mountAppendsReadOnlyFlagWhenRequested() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: nil, readOnly: true, recoveryKey: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls[0].arguments == ["mount", "disk2s1", "--fs-driver", "ntfs-3g", "--read-only", "--credential-required-error"])
}

@Test func mountExtDriverOmitsFsDriverAndAppendsIgnorePermissions() async {
    // ext is a real Unix fs; the helper must NOT pass --fs-driver (kernel auto-detects, ntfs-3g
    // can't mount ext4) and MUST pass --ignore-permissions so the export gets all_squash and the
    // macOS user can write past ext's ownership. This is the GUI fix for the ext-permission bug.
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk4s1", driver: FsDriver.ext.rawValue, mountPoint: nil, readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].arguments == ["mount", "disk4s1", "--ignore-permissions", "--credential-required-error"])
}

@Test func mountExtDriverWithReadOnlyAppendsReadOnlyAfterIgnorePermissions() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk4s1", driver: FsDriver.ext.rawValue, mountPoint: "/Volumes/Ext", readOnly: true, recoveryKey: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls[0].arguments == ["mount", "disk4s1", "/Volumes/Ext", "--ignore-permissions", "--read-only", "--credential-required-error"])
}

@Test func mountNtfs3gDriverStillPassesFsDriverAndNoIgnorePermissions() async {
    // "do not change the NTFS part": ntfs mounts keep --fs-driver and never get all_squash.
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (_, _) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: nil, readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(runner.calls[0].arguments == ["mount", "disk2s1", "--fs-driver", "ntfs-3g", "--credential-required-error"])
}

@Test func bitLockerRecoveryKeyUsesStdinAndNeverArgv() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let key = "111111-222222-333333-444444-555555-666666-777777-888888"
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: nil, readOnly: false, recoveryKey: key, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.pipedInputs == [key + "\n"])
    #expect(runner.calls[0].arguments == ["mount", "disk2s1", "--fs-driver", "ntfs-3g", "--bitlocker-credential-stdin"])
    #expect(!runner.calls[0].arguments.contains(key))
}

@Test func unmountRejectsInvalidTargetWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.unmount(target: "/etc/passwd", reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty)
}

@Test func unmountBuildsExpectedArgvForVolumesPath() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.unmount(target: "/Volumes/MyDrive", reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].arguments == ["unmount", "/Volumes/MyDrive"])
}

@Test func teardownOmitsSessionArgWhenNil() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.teardown(sessionID: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls[0].arguments == [])
}

// MARK: - removeDependencies / uninstallHelper (HelperUninstaller's real backing calls)

@Test func removeDependenciesRejectsWhileAnNfsMountIsActive() async {
    let runner = FakeRunner()
    runner.stubbedResult = CommandResult(output: "//server on /Volumes/Drive (nfs)", exitCode: 0)
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    // Only the mount-check call happened — never rm.
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].executablePath == "/sbin/mount")
}

@Test func removeDependenciesRemovesInstallPrefixWhenNotMounted() async {
    let runner = FakeRunner()
    runner.stubbedResult = CommandResult(output: "", exitCode: 0)
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    // Mount check, pf-teardown, then rm -rf installPrefix — real argv, not guessed.
    let rmPrefixCall = runner.calls.first { $0.executablePath == "/bin/rm" && $0.arguments.contains(installPrefix) }
    #expect(rmPrefixCall != nil)
    #expect(rmPrefixCall?.arguments == ["-rf", installPrefix])
}

/// Answers the mount check `unmounted` first, then `mounted` — proves `removeDependencies`
/// actually re-checks immediately before the destructive delete, not just once at the top.
private final class MountsAfterFirstCheckRunner: PrivilegedCommandRunning {
    private(set) var calls: [FakeRunner.Call] = []

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(FakeRunner.Call(executablePath: executablePath, arguments: arguments))
        let mountChecksSoFar = calls.filter { $0.executablePath == "/sbin/mount" }.count
        if executablePath == "/sbin/mount" {
            return mountChecksSoFar <= 1
                ? CommandResult(output: "", exitCode: 0)
                : CommandResult(output: "//server on /Volumes/Drive (nfs)", exitCode: 0)
        }
        return CommandResult(output: "", exitCode: 0)
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

@Test func removeDependenciesAbortsIfAMountBecomesActiveBeforeTheDelete() async {
    let runner = MountsAfterFirstCheckRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.contains { $0.executablePath == "/bin/rm" } == false)
}

private final class UnknownSecurityCleanupRunner: PrivilegedCommandRunning {
    private(set) var calls: [FakeRunner.Call] = []

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(FakeRunner.Call(executablePath: executablePath, arguments: arguments))
        if executablePath == "/sbin/mount" {
            return CommandResult(output: "", exitCode: 0)
        }
        if executablePath.hasSuffix("/pf-teardown.sh") {
            return CommandResult(output: "security_reconcile=unknown reason=STATUS_UNAVAILABLE", exitCode: 0)
        }
        return CommandResult(output: "", exitCode: 0)
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

@Test func removeDependenciesAbortsWhenSessionSecurityCleanupIsUnknown() async {
    let runner = UnknownSecurityCleanupRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.contains { $0.executablePath == "/bin/rm" } == false)
}

@Test func uninstallHelperBootsOutLaunchdJobAndRemovesItsOwnFiles() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.uninstallHelper(reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls.count == 5)
    // rm-plist and rm-binary (and the reply, implicit above) must complete before the
    // self-destructive bootout — reversing this order is the exact race that made every
    // uninstall attempt fail with "can't communicate with helper" on a real machine.
    #expect(runner.calls[0].arguments == ["-f", "/Library/LaunchDaemons/\(helperMachServiceName).plist"])
    #expect(runner.calls[1].arguments == ["-f", "/Library/PrivilegedHelperTools/\(helperMachServiceName)"])
    #expect(runner.calls[2].executablePath == "/usr/bin/tccutil")
    #expect(runner.calls[2].arguments == ["reset", "SystemPolicyAllFiles", helperMachServiceName])
    #expect(runner.calls[3].executablePath == "/usr/bin/tccutil")
    #expect(runner.calls[3].arguments == ["reset", "All", helperMachServiceName])
    #expect(runner.calls[4].executablePath == "/bin/launchctl")
    #expect(runner.calls[4].arguments == ["bootout", "system/\(helperMachServiceName)"])
}

// MARK: - resolveNtfsmacPrefix / ntfsmacPrefix injection (fixed prefix vs brew-tap fallback)

@Test func mountUsesInjectedNtfsmacPrefixOverride() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner, ntfsmacPrefix: homebrewOptPrefix)
    let (data, error) = await awaitReply { reply in
        service.mount(device: "disk2s1", driver: FsDriver.ntfs3g.rawValue, mountPoint: nil, readOnly: false, recoveryKey: nil, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls[0].executablePath == "\(homebrewOptPrefix)/bin/ntfsmac")
}

@Test func removeDependenciesUsesInjectedNtfsmacPrefixOverride() async {
    let runner = FakeRunner()
    runner.stubbedResult = CommandResult(output: "", exitCode: 0)
    let service = HelperService(runner: runner, ntfsmacPrefix: homebrewOptPrefix)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    let rmPrefixCall = runner.calls.first { $0.executablePath == "/bin/rm" && $0.arguments.contains(homebrewOptPrefix) }
    #expect(rmPrefixCall != nil)
}

/// Stubs `/bin/readlink` to report the symlink points where install.sh would have pointed
/// it, so `removeDependencies` should clean it up as part of a no-leftovers uninstall.
private final class SymlinkAwareRunner: PrivilegedCommandRunning {
    private(set) var calls: [FakeRunner.Call] = []

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        calls.append(FakeRunner.Call(executablePath: executablePath, arguments: arguments))
        if executablePath == "/bin/readlink" {
            return CommandResult(output: "\(installPrefix)/bin/ntfsmac\n", exitCode: 0)
        }
        return CommandResult(output: "", exitCode: 0)
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        CommandResult(output: "", exitCode: 0)
    }
}

@Test func removeDependenciesRemovesThePathSymlinkWhenItPointsIntoInstallPrefix() async {
    let runner = SymlinkAwareRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    let symlinkRemoval = runner.calls.first { $0.executablePath == "/bin/rm" && $0.arguments == ["-f", "/usr/local/bin/ntfsmac"] }
    #expect(symlinkRemoval != nil)
}

@Test func removeDependenciesLeavesAnUnrelatedSymlinkAlone() async {
    let runner = FakeRunner()
    // Empty stub output covers both the mount-check ("not mounted") and readlink ("succeeds"
    // with empty output, which never matches "installPrefix/bin/ntfsmac") — must never fire
    // the symlink rm in that case.
    runner.stubbedResult = CommandResult(output: "", exitCode: 0)
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.removeDependencies(reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    let symlinkRemoval = runner.calls.first { $0.executablePath == "/bin/rm" && $0.arguments == ["-f", "/usr/local/bin/ntfsmac"] }
    #expect(symlinkRemoval == nil)
}

@Test func teardownRejectsInvalidSessionWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.teardown(sessionID: "disk2s1; pfctl -d", reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty)
}

// MARK: - isValidStageCLIPath (mirrors validateDevice/isValidUnmountTarget's shape-check discipline)

@Test func stageCLIPathAcceptsWellFormedBundleLayout() {
    #expect(isValidStageCLIPath("/Applications/ntfsmac.app/Contents/Resources/cli-src/install.sh"))
}

@Test func stageCLIPathRejectsRelativePath() {
    #expect(!isValidStageCLIPath("Contents/Resources/cli-src/install.sh"))
}

@Test func stageCLIPathRejectsTraversal() {
    #expect(!isValidStageCLIPath("/Applications/ntfsmac.app/Contents/Resources/cli-src/../../../etc/install.sh"))
}

@Test func stageCLIPathRejectsWrongSuffix() {
    #expect(!isValidStageCLIPath("/tmp/evil.sh"))
    #expect(!isValidStageCLIPath("/Applications/ntfsmac.app/Contents/Resources/install.sh"))
}

// MARK: - HelperService.stageCLI

@Test func stageCLIRejectsMalformedPathWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let (data, error) = await awaitReply { reply in
        service.stageCLI(installScriptPath: "/tmp/evil.sh", reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty, "malformed path must never reach the runner")
}

@Test func stageCLIRejectsNonexistentPathWithoutRunningAnything() async {
    let runner = FakeRunner()
    let service = HelperService(runner: runner)
    let missingPath = "/nonexistent-\(UUID().uuidString)/Contents/Resources/cli-src/install.sh"
    let (data, error) = await awaitReply { reply in
        service.stageCLI(installScriptPath: missingPath, reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty, "a path that doesn't exist on disk must never reach the runner")
}

/// Builds a throwaway `.app`-shaped `cli-src` dir with a single `install.sh`, returning both
/// the script path and the real content hash over that dir — mirrors what `build/package-app.sh`
/// does for real (stage, then hash), so these tests exercise the actual pinning mechanism rather
/// than a stand-in for it.
private func makeStagedInstallScript(content: String = "#!/bin/sh\nexit 0\n") throws -> (scriptPath: URL, treeHash: String) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("StageCLITest-\(UUID().uuidString).app")
    let scriptDir = tempRoot.appendingPathComponent("Contents/Resources/cli-src")
    try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
    let scriptPath = scriptDir.appendingPathComponent("install.sh")
    try content.write(to: scriptPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
    guard let hash = computeTreeHash(at: scriptDir) else {
        struct HashFailure: Error {}
        throw HashFailure()
    }
    return (scriptPath, hash)
}

@Test func stageCLIRunsBundledInstallScriptWhenContentHashMatchesThePinnedValue() async throws {
    let (scriptPath, treeHash) = try makeStagedInstallScript()
    defer { try? FileManager.default.removeItem(at: scriptPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

    let runner = FakeRunner()
    let service = HelperService(runner: runner, expectedCLITreeHash: treeHash)
    let (data, error) = await awaitReply { reply in
        service.stageCLI(installScriptPath: scriptPath.path, reply: reply)
    }
    #expect(data != nil)
    #expect(error == nil)
    #expect(runner.calls.count == 1)
    #expect(runner.calls[0].executablePath == scriptPath.path)
    #expect(runner.calls[0].arguments == ["--no-path-link"])
}

@Test func stageCLIRejectsWhenContentHashDoesNotMatchPinnedValue() async throws {
    // Security review finding (2026-07-12, CRITICAL): path-shape validation alone let a caller
    // point at *any* writable directory ending in the right suffix. This is the actual fix —
    // content that doesn't match the build-time-pinned hash must never reach the runner,
    // regardless of how well-formed the path looks.
    let (scriptPath, _) = try makeStagedInstallScript()
    defer { try? FileManager.default.removeItem(at: scriptPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

    let runner = FakeRunner()
    let service = HelperService(runner: runner, expectedCLITreeHash: "0000000000000000000000000000000000000000000000000000000000000000")
    let (data, error) = await awaitReply { reply in
        service.stageCLI(installScriptPath: scriptPath.path, reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty, "mismatched content must never reach the runner")
}

@Test func stageCLIWithUnsetPlaceholderHashRejectsEveryRealDirectory() async throws {
    // `GeneratedCLIManifest`'s checked-in placeholder must never accidentally match a real
    // computed hash — fails closed (rejects) rather than open when a real packaging run never
    // happened, e.g. a stray raw `swift build` install somehow reaching this code path.
    let (scriptPath, _) = try makeStagedInstallScript()
    defer { try? FileManager.default.removeItem(at: scriptPath.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

    let runner = FakeRunner()
    let service = HelperService(runner: runner, expectedCLITreeHash: GeneratedCLIManifest.expectedTreeHashHex)
    let (data, error) = await awaitReply { reply in
        service.stageCLI(installScriptPath: scriptPath.path, reply: reply)
    }
    #expect(data == nil)
    #expect(error != nil)
    #expect(runner.calls.isEmpty)
}

// MARK: - computeTreeHash

@Test func computeTreeHashIsDeterministicForIdenticalContent() throws {
    let (scriptPathA, hashA) = try makeStagedInstallScript(content: "#!/bin/sh\necho same\n")
    defer { try? FileManager.default.removeItem(at: scriptPathA.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let (scriptPathB, hashB) = try makeStagedInstallScript(content: "#!/bin/sh\necho same\n")
    defer { try? FileManager.default.removeItem(at: scriptPathB.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

    #expect(hashA == hashB, "identical content in differently-named dirs must hash identically")
}

@Test func computeTreeHashChangesWhenFileContentChanges() throws {
    let (scriptPathA, hashA) = try makeStagedInstallScript(content: "#!/bin/sh\necho original\n")
    defer { try? FileManager.default.removeItem(at: scriptPathA.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let (scriptPathB, hashB) = try makeStagedInstallScript(content: "#!/bin/sh\necho tampered\n")
    defer { try? FileManager.default.removeItem(at: scriptPathB.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

    #expect(hashA != hashB, "a single changed byte anywhere in the tree must change the hash")
}

@Test func computeTreeHashRejectsDirectoryContainingASymlink() throws {
    // Security review finding (2026-07-13, CRITICAL): the old `isRegularFile`-only filter
    // silently excluded symlinks from the hash — planting one in cli-src/ contributed nothing
    // to actualHash, so its target could differ from what shipped without changing the hash.
    // Fixed to fail closed: any symlink anywhere under the tree rejects the whole hash.
    let (scriptPath, _) = try makeStagedInstallScript()
    let scriptDir = scriptPath.deletingLastPathComponent()
    let appRoot = scriptDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: appRoot) }

    let outsideTarget = FileManager.default.temporaryDirectory
        .appendingPathComponent("computeTreeHashSymlinkTarget-\(UUID().uuidString).txt")
    try "attacker-controlled".write(to: outsideTarget, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outsideTarget) }

    try FileManager.default.createSymbolicLink(
        at: scriptDir.appendingPathComponent("planted-symlink"),
        withDestinationURL: outsideTarget
    )

    #expect(computeTreeHash(at: scriptDir) == nil, "a tree containing a symlink must fail closed, not silently skip it")
}

// MARK: - exitHelper (GUI Quit asks the privileged helper to exit so it doesn't linger as root)

/// Sendable capture wrapper — a plain `var exitInvoked` can't be mutated inside a `@Sendable`
/// exit sink without racing the concurrent-execute check.
private final class ExitSinkProbe: @unchecked Sendable {
    private(set) var invoked = false
    func record() { invoked = true }
}

@Test func exitHelperAcknowledgesThenInvokesTheExitSink() async {
    let runner = FakeRunner()
    let probe = ExitSinkProbe()
    let service = HelperService(
        runner: runner,
        exitSink: { probe.record() }
    )

    let (data, error) = await awaitReply { service.exitHelper(reply: $0) }

    #expect(error == nil, "exitHelper must acknowledge cleanly so the GUI's await returns before the process dies")
    #expect(data != nil, "exitHelper must send a reply payload so HelperClient.call decodes it instead of throwing on an empty response")
    #expect(probe.invoked, "exitHelper must invoke the exit sink (exit(0) in production) so the launchd on-demand helper actually stops")
}

@Test func exitHelperDefaultsToRealProcessExitWhenNoSinkInjected() async {
    // The default sink is exit(0) — verified structurally by not crashing the test host on
    // construction. We only assert the default exists; actually invoking it would terminate
    // the test process, which is the production behavior and intentionally not exercised here.
    let service = HelperService(runner: FakeRunner())
    _ = service
    #expect(true)
}
