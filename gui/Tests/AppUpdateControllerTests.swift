import Foundation
import Testing
@testable import NtfsmacGUI

private struct FakeReleaseCheckService: ReleaseChecking {
    let result: Result<ReleaseUpdateInfo?, Error>

    func checkForUpdates(currentVersion: ProductVersion) async throws -> ReleaseUpdateInfo? {
        try result.get()
    }
}

private struct FakeUpdateDownloadService: UpdateDownloading {
    let result: Result<URL, Error>

    func download(from url: URL, progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        progress(0.5)
        progress(1.0)
        return try result.get()
    }
}

private struct FakeUpdateExtractionService: UpdateExtracting {
    let result: Result<URL, Error>

    func extractAndValidate(dmgURL: URL) async throws -> URL {
        try result.get()
    }

    func extractAndValidate(dmgURL: URL, signatureData: Data?) async throws -> URL {
        try result.get()
    }
}

private final class FakeAppRelaunchService: AppRelaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _relaunchCalled = false

    var relaunchCalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _relaunchCalled
    }

    func relaunchAndSwap(stagedAppURL: URL, targetAppURL: URL, hasActiveMounts: Bool) throws {
        if hasActiveMounts {
            throw AppRelaunchError.activeMountsPresent
        }
        lock.lock()
        _relaunchCalled = true
        lock.unlock()
    }
}

@MainActor
@Test func controllerTransitionsFromIdleToCheckingThenUpToDate() async {
    let checkService = FakeReleaseCheckService(result: .success(nil))
    let controller = AppUpdateController(
        checkService: checkService,
        productVersionProvider: { ProductVersion(release: "2.3", build: "040926") }
    )

    #expect(controller.state == .idle)
    await controller.checkForUpdates()
    #expect(controller.state == .upToDate)
}

@MainActor
@Test func controllerTransitionsToUpdateAvailableWhenNewerVersionFound() async {
    let info = ReleaseUpdateInfo(
        tagName: "v2.4.0",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
        assetSize: 1000,
        releaseNotes: "New features"
    )
    let checkService = FakeReleaseCheckService(result: .success(info))
    let controller = AppUpdateController(
        checkService: checkService,
        productVersionProvider: { ProductVersion(release: "2.3", build: "040926") }
    )

    await controller.checkForUpdates()
    #expect(controller.state == .updateAvailable(info))
}

@MainActor
@Test func controllerSurfacesErrorWhenCheckFails() async {
    let checkService = FakeReleaseCheckService(result: .failure(ReleaseCheckError.badHTTPStatus(500)))
    let controller = AppUpdateController(
        checkService: checkService,
        productVersionProvider: { ProductVersion(release: "2.3", build: "040926") }
    )

    await controller.checkForUpdates()
    if case .failed(let msg) = controller.state {
        #expect(!msg.isEmpty)
    } else {
        Issue.record("Expected .failed state")
    }
}

@MainActor
@Test func controllerDownloadAndPrepareFlowCompletesToReadyToRestart() async {
    let info = ReleaseUpdateInfo(
        tagName: "v2.4.0",
        dmgURL: URL(string: "https://github.com/khr898/ntfsmac/releases/download/v2.4.0/ntfsmac.dmg")!,
        assetSize: 1000,
        releaseNotes: "New features"
    )
    let fakeDMG = URL(fileURLWithPath: "/tmp/fake.dmg")
    let stagedApp = URL(fileURLWithPath: "/tmp/staged.app")

    let checkService = FakeReleaseCheckService(result: .success(info))
    let downloadService = FakeUpdateDownloadService(result: .success(fakeDMG))
    let extractionService = FakeUpdateExtractionService(result: .success(stagedApp))
    let relaunchService = FakeAppRelaunchService()

    let controller = AppUpdateController(
        checkService: checkService,
        downloadService: downloadService,
        extractionService: extractionService,
        relaunchService: relaunchService,
        productVersionProvider: { ProductVersion(release: "2.3", build: "040926") }
    )

    await controller.checkForUpdates()
    #expect(controller.state == .updateAvailable(info))

    await controller.downloadAndPrepare()
    #expect(controller.state == .readyToRestart(stagedAppURL: stagedApp, version: "2.4.0"))

    // Test restart with active mounts blocks
    controller.restartAndApply(hasActiveMounts: true)
    if case .failed(let msg) = controller.state {
        #expect(msg.contains("active drives") || msg.contains("active mounts") || msg.contains("mounted"))
    } else {
        Issue.record("Expected .failed when restarting with active mounts")
    }

    // Reset back to readyToRestart for success test
    controller.forceStateForTesting(.readyToRestart(stagedAppURL: stagedApp, version: "2.4.0"))
    controller.restartAndApply(hasActiveMounts: false)
    #expect(relaunchService.relaunchCalled)
}
