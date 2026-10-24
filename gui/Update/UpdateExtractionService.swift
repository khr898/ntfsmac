import Foundation
import HelperShared

public func hasQuarantineAttribute(at url: URL) -> Bool {
    if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 { return true }
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let fileURL as URL in enumerator {
            if getxattr(fileURL.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 { return true }
        }
    }
    return false
}

public func stripQuarantineRecursively(at url: URL) {
    removexattr(url.path, "com.apple.quarantine", 0)
    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let fileURL as URL in enumerator {
            removexattr(fileURL.path, "com.apple.quarantine", 0)
        }
    }
}

extension RealCommandRunner: @unchecked Sendable {}

public enum UpdateExtractionError: Error, Equatable, Sendable {
    case mountFailed(String)
    case bundleNotFound
    case invalidBundleStructure(String)
    case codeSignatureInvalid
    case signatureVerificationFailed(String)
    case extractionFailed(String)
}

public protocol UpdateExtracting: Sendable {
    func extractAndValidate(dmgURL: URL) async throws -> URL
    func extractAndValidate(dmgURL: URL, signatureData: Data?) async throws -> URL
}

extension UpdateExtracting {
    public func extractAndValidate(dmgURL: URL) async throws -> URL {
        try await extractAndValidate(dmgURL: dmgURL, signatureData: nil)
    }

    public func extractAndValidate(dmgURL: URL, signatureData: Data?) async throws -> URL {
        try await extractAndValidate(dmgURL: dmgURL)
    }
}

public struct RealUpdateExtractionService: UpdateExtracting {
    private let runner: any (PrivilegedCommandRunning & Sendable)
    private let onMountAttachment: (@Sendable (URL, URL) -> Void)?
    private let signatureVerifier: (any UpdateSignatureVerifying)?

    public init(
        runner: any (PrivilegedCommandRunning & Sendable) = RealCommandRunner(),
        signatureVerifier: (any UpdateSignatureVerifying)? = try? CryptoKitUpdateSignatureVerifier(),
        onMountAttachment: (@Sendable (URL, URL) -> Void)? = nil
    ) {
        self.runner = runner
        self.signatureVerifier = signatureVerifier
        self.onMountAttachment = onMountAttachment
    }

    public func extractAndValidate(dmgURL: URL, signatureData: Data?) async throws -> URL {
        // Pre-mount cryptographic authenticity verification: release DMGs must be signed
        // offline with an authorized Ed25519 key. Verifying the signature BEFORE hdiutil attach
        // ensures that malformed or tampered DMGs are never mounted or executed.
        if let verifier = signatureVerifier {
            guard let signatureData else {
                try? FileManager.default.removeItem(at: dmgURL)
                throw UpdateExtractionError.signatureVerificationFailed("Missing cryptographic release signature for DMG")
            }
            do {
                _ = try verifier.verify(dmgURL: dmgURL, signatureData: signatureData)
            } catch {
                try? FileManager.default.removeItem(at: dmgURL)
                throw UpdateExtractionError.signatureVerificationFailed("Cryptographic signature verification failed: \(error)")
            }
        }

        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("ntfsmac-mount-\(UUID().uuidString)")
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachResult = runner.run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", dmgURL.path, "-mountpoint", mountPoint.path
        ])

        defer {
            _ = runner.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fileManager.removeItem(at: mountPoint)
            try? fileManager.removeItem(at: dmgURL)
        }

        guard attachResult.exitCode == 0 else {
            throw UpdateExtractionError.mountFailed(attachResult.output)
        }

        onMountAttachment?(dmgURL, mountPoint)

        let mountedApp = mountPoint.appendingPathComponent("ntfsmac.app")
        guard fileManager.fileExists(atPath: mountedApp.path) else {
            throw UpdateExtractionError.bundleNotFound
        }

        let stagedDir = fileManager.temporaryDirectory
            .appendingPathComponent("ntfsmac-staged-\(UUID().uuidString)")
        try fileManager.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedApp = stagedDir.appendingPathComponent("ntfsmac.app")

        do {
            try fileManager.copyItem(at: mountedApp, to: stagedApp)
        } catch {
            throw UpdateExtractionError.extractionFailed(error.localizedDescription)
        }

        // Validate bundle structure
        let contents = stagedApp.appendingPathComponent("Contents")
        let infoPlist = contents.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: infoPlist.path) else {
            throw UpdateExtractionError.invalidBundleStructure("Missing Contents/Info.plist")
        }

        let guiExecutable = contents.appendingPathComponent("MacOS/ntfsmac-gui")
        guard fileManager.isExecutableFile(atPath: guiExecutable.path) else {
            throw UpdateExtractionError.invalidBundleStructure("Missing main executable ntfsmac-gui")
        }

        let helperExecutable = contents.appendingPathComponent("Library/LaunchServices/com.khr898.ntfsmac.helper")
        guard fileManager.isExecutableFile(atPath: helperExecutable.path) else {
            throw UpdateExtractionError.invalidBundleStructure("Missing privileged helper tool")
        }

        let installScript = contents.appendingPathComponent("Resources/cli-src/install.sh")
        guard fileManager.isExecutableFile(atPath: installScript.path) else {
            throw UpdateExtractionError.invalidBundleStructure("Missing bundled install.sh")
        }

        // Validate structural code signature
        let codesignResult = runner.run("/usr/bin/codesign", ["-v", stagedApp.path])
        guard codesignResult.exitCode == 0 else {
            throw UpdateExtractionError.codeSignatureInvalid
        }

        // Strip Gatekeeper quarantine
        stripQuarantineRecursively(at: stagedApp)

        return stagedApp
    }
}
