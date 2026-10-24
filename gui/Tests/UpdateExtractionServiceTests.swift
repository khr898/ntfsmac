import Foundation
import Testing
import HelperShared
@testable import NtfsmacGUI

private final class FakeCommandRunner: PrivilegedCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [(path: String, args: [String])] = []
    var codesignExitCode: Int32 = 0
    var hdiutilAttachMountPoint: String?

    var invocations: [(path: String, args: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(_ executablePath: String, _ arguments: [String]) -> CommandResult {
        lock.lock()
        _invocations.append((executablePath, arguments))
        lock.unlock()

        if executablePath.hasSuffix("hdiutil") {
            return CommandResult(output: "attached", exitCode: 0)
        }
        if executablePath.hasSuffix("codesign") {
            return CommandResult(output: "codesign result", exitCode: codesignExitCode)
        }
        return CommandResult(output: "", exitCode: 0)
    }

    func runPipingStdin(_ input: String, to executablePath: String, _ arguments: [String]) -> CommandResult {
        run(executablePath, arguments)
    }
}

private func createMockBundle(at destination: URL, missing: [String] = []) throws {
    let fm = FileManager.default
    let contents = destination.appendingPathComponent("Contents")
    let macos = contents.appendingPathComponent("MacOS")
    let launchServices = contents.appendingPathComponent("Library/LaunchServices")
    let cliSrc = contents.appendingPathComponent("Resources/cli-src")

    try fm.createDirectory(at: macos, withIntermediateDirectories: true)
    try fm.createDirectory(at: launchServices, withIntermediateDirectories: true)
    try fm.createDirectory(at: cliSrc, withIntermediateDirectories: true)

    if !missing.contains("Info.plist") {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.khr898.ntfsmac</string>
            <key>CFBundleShortVersionString</key>
            <string>2.4.0</string>
            <key>CFBundleVersion</key>
            <string>050926</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }

    if !missing.contains("gui") {
        let guiPath = macos.appendingPathComponent("ntfsmac-gui")
        try "binary".write(to: guiPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guiPath.path)
    }

    if !missing.contains("helper") {
        let helperPath = launchServices.appendingPathComponent("com.khr898.ntfsmac.helper")
        try "helper-binary".write(to: helperPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperPath.path)
    }

    if !missing.contains("install.sh") {
        let installPath = cliSrc.appendingPathComponent("install.sh")
        try "#!/bin/sh\necho ok".write(to: installPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installPath.path)
    }
}

@Test func extractAndValidateExtractsAndVerifiesValidBundle() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mockMount = tempDir.appendingPathComponent("mount")
    let mockApp = mockMount.appendingPathComponent("ntfsmac.app")
    try createMockBundle(at: mockApp)

    let runner = FakeCommandRunner()
    let service = RealUpdateExtractionService(runner: runner, signatureVerifier: nil) { _, mountPoint in
        // Simulate hdiutil attach populating the mount point
        try? FileManager.default.copyItem(at: mockApp, to: mountPoint.appendingPathComponent("ntfsmac.app"))
    }

    let fakeDMG = tempDir.appendingPathComponent("update.dmg")
    try "dummy".write(to: fakeDMG, atomically: true, encoding: .utf8)

    let stagedApp = try await service.extractAndValidate(dmgURL: fakeDMG)
    defer { try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent()) }

    #expect(FileManager.default.fileExists(atPath: stagedApp.appendingPathComponent("Contents/MacOS/ntfsmac-gui").path))
    #expect(FileManager.default.fileExists(atPath: stagedApp.appendingPathComponent("Contents/Library/LaunchServices/com.khr898.ntfsmac.helper").path))
    #expect(runner.invocations.contains { $0.path == "/usr/bin/codesign" })
    #expect(runner.invocations.contains { $0.path == "/usr/bin/hdiutil" && $0.args.first == "detach" })
}

@Test func extractAndValidateFailsIfMachOExecutableIsMissing() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mockMount = tempDir.appendingPathComponent("mount")
    let mockApp = mockMount.appendingPathComponent("ntfsmac.app")
    try createMockBundle(at: mockApp, missing: ["gui"])

    let runner = FakeCommandRunner()
    let service = RealUpdateExtractionService(runner: runner, signatureVerifier: nil) { _, mountPoint in
        try? FileManager.default.copyItem(at: mockApp, to: mountPoint.appendingPathComponent("ntfsmac.app"))
    }

    let fakeDMG = tempDir.appendingPathComponent("update.dmg")
    try "dummy".write(to: fakeDMG, atomically: true, encoding: .utf8)

    await #expect(throws: UpdateExtractionError.invalidBundleStructure("Missing main executable ntfsmac-gui")) {
        _ = try await service.extractAndValidate(dmgURL: fakeDMG)
    }
}

@Test func extractAndValidateFailsIfCodesignVerificationFails() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mockMount = tempDir.appendingPathComponent("mount")
    let mockApp = mockMount.appendingPathComponent("ntfsmac.app")
    try createMockBundle(at: mockApp)

    let runner = FakeCommandRunner()
    runner.codesignExitCode = 1 // simulate broken signature
    let service = RealUpdateExtractionService(runner: runner, signatureVerifier: nil) { _, mountPoint in
        try? FileManager.default.copyItem(at: mockApp, to: mountPoint.appendingPathComponent("ntfsmac.app"))
    }

    let fakeDMG = tempDir.appendingPathComponent("update.dmg")
    try "dummy".write(to: fakeDMG, atomically: true, encoding: .utf8)

    await #expect(throws: UpdateExtractionError.codeSignatureInvalid) {
        _ = try await service.extractAndValidate(dmgURL: fakeDMG)
    }
}

@Test func extractAndValidateStripsQuarantineAttribute() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mockMount = tempDir.appendingPathComponent("mount")
    let mockApp = mockMount.appendingPathComponent("ntfsmac.app")
    try createMockBundle(at: mockApp)

    // Stamp quarantine attribute
    let quarantineVal = "0081;64c12345;Safari;".data(using: .utf8)!
    setxattr(mockApp.path, "com.apple.quarantine", (quarantineVal as NSData).bytes, quarantineVal.count, 0, 0)
    #expect(hasQuarantineAttribute(at: mockApp))

    let runner = FakeCommandRunner()
    let service = RealUpdateExtractionService(runner: runner, signatureVerifier: nil) { _, mountPoint in
        try? FileManager.default.copyItem(at: mockApp, to: mountPoint.appendingPathComponent("ntfsmac.app"))
    }

    let fakeDMG = tempDir.appendingPathComponent("update.dmg")
    try "dummy".write(to: fakeDMG, atomically: true, encoding: .utf8)

    let stagedApp = try await service.extractAndValidate(dmgURL: fakeDMG)
    defer { try? FileManager.default.removeItem(at: stagedApp.deletingLastPathComponent()) }

    #expect(!hasQuarantineAttribute(at: stagedApp))
}
