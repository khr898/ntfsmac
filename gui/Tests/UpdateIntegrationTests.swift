import Foundation
import Testing
import CryptoKit
import HelperShared
@testable import NtfsmacGUI

private final class ThreadSafeState: @unchecked Sendable {
    private let lock = NSLock()
    var scriptExecuted = false
    var terminated = false
    var scriptContent: String?
    var scriptArgs: [String]?

    func recordScript(url: URL, args: [String]) {
        lock.lock()
        defer { lock.unlock() }
        scriptExecuted = true
        scriptContent = try? String(contentsOf: url, encoding: .utf8)
        scriptArgs = args
    }

    func recordTermination() {
        lock.lock()
        defer { lock.unlock() }
        terminated = true
    }

    var isTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }

    var wasScriptExecuted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return scriptExecuted
    }

    var capturedContent: String? {
        lock.lock()
        defer { lock.unlock() }
        return scriptContent
    }

    var capturedArgs: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return scriptArgs
    }
}

@Suite(.serialized)
struct UpdateIntegrationTests {

    @Test func liveGitHubReleaseCheckDetectsCurrentAndOlderVersions() async throws {
        let service = GitHubReleaseCheckService()

        func checkWithTolerance(version: ProductVersion) async throws -> ReleaseUpdateInfo?? {
            do {
                let info = try await service.checkForUpdates(currentVersion: version)
                return .some(info)
            } catch let error as ReleaseCheckError {
                switch error {
                case .badHTTPStatus(let code) where code == 403 || code == 429:
                    // Rate-limited by GitHub unauthenticated API limit (common in CI runner IP blocks)
                    return nil
                default:
                    throw error
                }
            } catch is URLError {
                // Offline or network unavailable in CI runner environment
                return nil
            }
        }

        // 1. Check with a simulated older version (e.g. 0.1 / build 010101)
        guard let updateForOlder = try await checkWithTolerance(version: ProductVersion(release: "0.1", build: "010101")) else {
            // Skipped due to rate-limiting or offline environment
            return
        }

        #expect(updateForOlder != nil, "Expected GitHub to report an update for older version 0.1")
        guard let update = updateForOlder else { return }

        // Verify invariant properties of the published release asset
        #expect(!update.tagName.isEmpty)
        #expect(!update.version.isEmpty)
        #expect(update.dmgURL.host == "github.com" || update.dmgURL.host?.hasSuffix(".githubusercontent.com") == true)
        #expect(update.dmgURL.lastPathComponent.hasSuffix(".dmg"))
        #expect(update.assetSize > 1_000_000, "DMG size should be a valid multi-megabyte bundle")

        // 2. Check with the latest version dynamically reported by GitHub
        let latestVersion = ProductVersion(release: update.version, build: update.build)
        if let updateForCurrent = try await checkWithTolerance(version: latestVersion) {
            #expect(updateForCurrent == nil, "Expected GitHub to report nil (up to date) for latest version \(update.version)")
        }

        // 3. Check with a hypothetical future version (e.g. 999.0 / build 999999)
        let futureVersion = ProductVersion(release: "999.0", build: "999999")
        if let updateForFuture = try await checkWithTolerance(version: futureVersion) {
            #expect(updateForFuture == nil, "Expected GitHub to report nil (up to date) for future version 999.0")
        }
    }

    @Test func realDMGExtractionAndIntegrityValidation() async throws {
        let sourceDMG = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/ntfsmac.dmg")

        guard FileManager.default.fileExists(atPath: sourceDMG.path) else {
            // Skip in environments where dist/ntfsmac.dmg hasn't been built beforehand (e.g. CI swift-build)
            return
        }

        // Copy DMG to a temporary location because extractAndValidate cleans up the input dmgURL
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-int-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testDMG = tempDir.appendingPathComponent("ntfsmac.dmg")
        try FileManager.default.copyItem(at: sourceDMG, to: testDMG)

        // Generate test Ed25519 keypair and sign testDMG
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CryptoKitUpdateSignatureVerifier(publicKey: privateKey.publicKey)
        let dmgData = try Data(contentsOf: testDMG)
        let sig = try privateKey.signature(for: dmgData)

        let service = RealUpdateExtractionService(signatureVerifier: verifier)
        let stagedApp = try await service.extractAndValidate(dmgURL: testDMG, signatureData: sig)
        defer { try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent()) }

        // Verify staged bundle exists and structure is intact
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: stagedApp.path))

        let infoPlist = stagedApp.appendingPathComponent("Contents/Info.plist")
        #expect(fm.fileExists(atPath: infoPlist.path))

        let guiBin = stagedApp.appendingPathComponent("Contents/MacOS/ntfsmac-gui")
        #expect(fm.isExecutableFile(atPath: guiBin.path))

        let helperBin = stagedApp.appendingPathComponent("Contents/Library/LaunchServices/com.khr898.ntfsmac.helper")
        #expect(fm.isExecutableFile(atPath: helperBin.path))

        let installSh = stagedApp.appendingPathComponent("Contents/Resources/cli-src/install.sh")
        #expect(fm.isExecutableFile(atPath: installSh.path))

        // Verify codesign verification passed
        let codesignProcess = Process()
        codesignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesignProcess.arguments = ["-v", stagedApp.path]
        try codesignProcess.run()
        codesignProcess.waitUntilExit()
        #expect(codesignProcess.terminationStatus == 0)

        // Verify quarantine attribute is absent
        #expect(!hasQuarantineAttribute(at: stagedApp))

        // Verify test DMG was cleaned up
        #expect(!fm.fileExists(atPath: testDMG.path))
    }

    @Test func activeMountGuardBlocksRelaunchWhenDrivesAreMounted() throws {
        let state = ThreadSafeState()

        let service = RealAppRelaunchService(
            scriptSpawner: { url, args in state.recordScript(url: url, args: args) },
            terminator: { state.recordTermination() }
        )

        let dummyApp = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.app")

        #expect(throws: AppRelaunchError.activeMountsPresent) {
            try service.relaunchAndSwap(
                stagedAppURL: dummyApp,
                targetAppURL: dummyApp,
                hasActiveMounts: true
            )
        }

        #expect(!state.wasScriptExecuted)
        #expect(!state.isTerminated)
    }

    @Test func relaunchGeneratesValidSwapScriptWhenUnmounted() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ntfsmac-relaunch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create mock staged app with executable
        let stagedApp = tempDir.appendingPathComponent("staged.app")
        let stagedBinDir = stagedApp.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: stagedBinDir, withIntermediateDirectories: true)
        let stagedBin = stagedBinDir.appendingPathComponent("ntfsmac-gui")
        try "binary".write(to: stagedBin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBin.path)

        let targetApp = tempDir.appendingPathComponent("target.app")

        let state = ThreadSafeState()

        let service = RealAppRelaunchService(
            scriptSpawner: { url, args in state.recordScript(url: url, args: args) },
            terminator: { state.recordTermination() }
        )

        try service.relaunchAndSwap(
            stagedAppURL: stagedApp,
            targetAppURL: targetApp,
            hasActiveMounts: false
        )

        #expect(state.isTerminated)
        #expect(state.wasScriptExecuted)
        guard let scriptContent = state.capturedContent, let args = state.capturedArgs else {
            Issue.record("Script was not captured")
            return
        }

        #expect(scriptContent.contains("rm -rf \"$TARGET\""))
        #expect(scriptContent.contains("cp -R \"$STAGED\" \"$TARGET\""))
        #expect(scriptContent.contains("xattr -dr com.apple.quarantine \"$TARGET\""))
        #expect(scriptContent.contains("open \"$TARGET\""))

        #expect(args.count == 3)
        #expect(args[1] == stagedApp.path)
        #expect(args[2] == targetApp.path)
    }

    @Test func ed25519SignatureVerificationAcceptsValidSignature() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CryptoKitUpdateSignatureVerifier(publicKey: privateKey.publicKey)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sig-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgFile = tempDir.appendingPathComponent("test.dmg")
        let dmgData = Data("test-dmg-payload".utf8)
        try dmgData.write(to: dmgFile)

        let signature = try privateKey.signature(for: dmgData)
        let isValid = try verifier.verify(dmgURL: dmgFile, signatureData: signature)
        #expect(isValid)
    }

    @Test func ed25519SignatureVerificationRejectsTamperedDMG() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CryptoKitUpdateSignatureVerifier(publicKey: privateKey.publicKey)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sig-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgFile = tempDir.appendingPathComponent("test.dmg")
        let dmgData = Data("original-dmg-payload".utf8)
        try dmgData.write(to: dmgFile)
        let signature = try privateKey.signature(for: dmgData)

        // Tamper with the DMG
        try Data("tampered-dmg-payload".utf8).write(to: dmgFile)

        #expect(throws: SignatureVerificationError.signatureMismatch) {
            _ = try verifier.verify(dmgURL: dmgFile, signatureData: signature)
        }
    }

    @Test func extractionServiceRejectsUnsignedDMGBeforeMounting() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let verifier = CryptoKitUpdateSignatureVerifier(publicKey: privateKey.publicKey)
        let service = RealUpdateExtractionService(signatureVerifier: verifier)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("sig-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dmgFile = tempDir.appendingPathComponent("test.dmg")
        try Data("dummy".utf8).write(to: dmgFile)

        do {
            _ = try await service.extractAndValidate(dmgURL: dmgFile, signatureData: nil)
            Issue.record("Expected signatureVerificationFailed error")
        } catch UpdateExtractionError.signatureVerificationFailed {
            // Expected
        }
    }
}
