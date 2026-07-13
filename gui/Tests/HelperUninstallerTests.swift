import Foundation
import Testing
import HelperShared
@testable import NtfsmacGUI

// "Uninstall ntfsmac" flow: removeDependencies then uninstallHelper, always in that order —
// uninstallHelper makes the mach service disappear, so nothing can follow it.

private final class FakeUninstallClient: HelperUninstalling {
    private(set) var calls: [String] = []
    var removeDependenciesResult: Result<CommandResult, Error> = .success(CommandResult(output: "removed", exitCode: 0))
    var uninstallHelperResult: Result<CommandResult, Error> = .success(CommandResult(output: "uninstalled", exitCode: 0))

    func removeDependencies() async throws -> CommandResult {
        calls.append("removeDependencies")
        return try removeDependenciesResult.get()
    }

    func uninstallHelper() async throws -> CommandResult {
        calls.append("uninstallHelper")
        return try uninstallHelperResult.get()
    }
}

@MainActor
@Test func uninstallEverythingCallsRemoveDependenciesBeforeUninstallHelper() async {
    let fake = FakeUninstallClient()
    let uninstaller = HelperUninstaller(client: fake)

    await uninstaller.uninstallEverything()

    #expect(fake.calls == ["removeDependencies", "uninstallHelper"])
    #expect(uninstaller.state == .done("removed"))
}

@MainActor
@Test func uninstallEverythingStopsBeforeUninstallHelperWhenDependenciesRemovalFails() async {
    let fake = FakeUninstallClient()
    fake.removeDependenciesResult = .success(CommandResult(output: "rejected: an NFS mount is currently active", exitCode: 1))
    let uninstaller = HelperUninstaller(client: fake)

    await uninstaller.uninstallEverything()

    // The real safety property: never un-bless the helper if dependency removal failed
    // (e.g. an active mount) — the user would be left with a helper but no way to unmount.
    #expect(fake.calls == ["removeDependencies"])
    #expect(uninstaller.state == .failed("rejected: an NFS mount is currently active"))
}

@MainActor
@Test func uninstallEverythingSurfacesUninstallHelperFailure() async {
    let fake = FakeUninstallClient()
    fake.uninstallHelperResult = .success(CommandResult(output: "launchctl bootout failed", exitCode: 1))
    let uninstaller = HelperUninstaller(client: fake)

    await uninstaller.uninstallEverything()

    #expect(fake.calls == ["removeDependencies", "uninstallHelper"])
    #expect(uninstaller.state == .failed("launchctl bootout failed"))
}

@MainActor
@Test func uninstallEverythingSurfacesThrownErrorsAsPlainLanguage() async {
    let fake = FakeUninstallClient()
    fake.removeDependenciesResult = .failure(HelperClientError.proxyUnavailable)
    let uninstaller = HelperUninstaller(client: fake)

    await uninstaller.uninstallEverything()

    #expect(uninstaller.state == .failed("Privileged helper is not installed or not responding"))
}
