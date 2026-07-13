import Foundation
import Testing
@testable import NtfsmacGUI
@testable import HelperShared

@MainActor
final class FakeCLIStaging: CLIStaging {
    struct Call: Equatable { var installScriptPath: String }
    private(set) var calls: [Call] = []
    var stubbedResult = CommandResult(output: "ok", exitCode: 0)
    var stubbedError: Error?

    func stageCLI(installScriptPath: String) async throws -> CommandResult {
        calls.append(Call(installScriptPath: installScriptPath))
        if let stubbedError { throw stubbedError }
        return stubbedResult
    }
}

@MainActor @Test func stageIfNeededSkipsWhenCLIAlreadyInstalled() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let binPath = dir.appendingPathComponent("ntfsmac").path
    FileManager.default.createFile(atPath: binPath, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)

    let checker = CLIInstallChecker(candidatePaths: [binPath])
    let helper = FakeCLIStaging()
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"))

    await stager.stageIfNeeded()

    #expect(helper.calls.isEmpty, "CLI already present — must never invoke the privileged stage command")
}

@MainActor @Test func stageIfNeededCallsHelperWithBundledInstallScriptPath() async {
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"))

    await stager.stageIfNeeded()

    #expect(helper.calls.count == 1)
    #expect(helper.calls[0].installScriptPath == "/Applications/ntfsmac.app/Contents/Resources/cli-src/install.sh")
}

@MainActor @Test func stageIfNeededOnlyAttemptsOncePerLaunch() async {
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"))

    await stager.stageIfNeeded()
    await stager.stageIfNeeded()

    #expect(helper.calls.count == 1, "staging failed and CLI still isn't present — must not retry silently in a loop")
}

@MainActor @Test func stageIfNeededDoesNothingWithoutAResolvableBundleURL() async {
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: nil)

    await stager.stageIfNeeded()

    #expect(helper.calls.isEmpty)
}

@MainActor @Test func stageIfNeededSurfacesTheFailureReasonWhenStagingThrows() async {
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    helper.stubbedError = HelperClientError.helper("rejected: cli-src content does not match the hash pinned into this helper at build time — refusing (possible tampering)")
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"), connectionRetryDelayNanoseconds: 1_000_000)

    await stager.stageIfNeeded()

    #expect(stager.lastFailureReason == "rejected: cli-src content does not match the hash pinned into this helper at build time — refusing (possible tampering)")
}

@MainActor @Test func stageIfNeededSurfacesTheFailureReasonWhenInstallScriptExitsNonzero() async {
    // Silent-failure-hunter finding (2026-07-13, CRITICAL): `stageCLI` only *throws* on its own
    // input-validation guards — a real `install.sh` failure (bad arch, codesign failure) still
    // replies with XPC success, carrying a nonzero exitCode and the real diagnostic text in
    // `result.output`. That text must not be silently discarded.
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    helper.stubbedResult = CommandResult(output: "install.sh: HARD-STOP — ntfsmac requires Apple Silicon (arm64), detected 'x86_64'", exitCode: 1)
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"))

    await stager.stageIfNeeded()

    #expect(stager.lastFailureReason == "install.sh: HARD-STOP — ntfsmac requires Apple Silicon (arm64), detected 'x86_64'")
}

@MainActor @Test func retryBypassesTheOneShotGuardAndClearsTheFailureReasonOnSuccess() async {
    // The automatic attempt (`stageIfNeeded`) fails and sets `didAttempt` — a second automatic
    // call must stay a no-op (`stageIfNeededOnlyAttemptsOncePerLaunch` covers that). `retry()` is
    // the explicit exception: an in-app button tap must still be able to try again and clear a
    // stale failure reason once it succeeds. Doesn't assert an exact call count for the first
    // attempt — `attemptStage()` internally blanket-retries a connection-level error up to
    // `connectionRetryAttempts` times on its own (see `CLIAutoStager.swift`), so a permanently-set
    // `stubbedError` legitimately drives multiple calls before `stageIfNeeded()` even returns.
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac"])
    let helper = FakeCLIStaging()
    helper.stubbedError = HelperClientError.proxyUnavailable
    let stager = CLIAutoStager(helper: helper, checker: checker, bundleResourcesURL: URL(fileURLWithPath: "/Applications/ntfsmac.app/Contents/Resources"), connectionRetryDelayNanoseconds: 1_000_000)

    await stager.stageIfNeeded()
    let callsAfterFirstAttempt = helper.calls.count
    #expect(callsAfterFirstAttempt > 0)
    #expect(stager.lastFailureReason != nil)

    helper.stubbedError = nil
    await stager.retry()

    #expect(helper.calls.count == callsAfterFirstAttempt + 1, "retry() must actually re-invoke staging, not just re-check the filesystem")
    #expect(stager.lastFailureReason == nil)
}
