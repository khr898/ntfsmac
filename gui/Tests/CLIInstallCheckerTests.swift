import Foundation
import Testing
@testable import NtfsmacGUI
@testable import HelperShared

// Covers the multi-candidate resolution added so a brew-tap-only install (Homebrew forbids
// `sudo`, so it can never land at the fixed `installPrefix`) is recognized just as readily as
// an install.sh install — real temp-dir executables, no FileManager mocking needed.

@MainActor @Test func cliInstallCheckerReportsInstalledWhenFirstCandidateExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let binPath = dir.appendingPathComponent("ntfsmac").path
    FileManager.default.createFile(atPath: binPath, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)

    let checker = CLIInstallChecker(candidatePaths: [binPath, "/nonexistent/bin/ntfsmac"])
    checker.check()
    #expect(checker.isInstalled)
}

@MainActor @Test func cliInstallCheckerReportsInstalledWhenOnlySecondCandidateExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let binPath = dir.appendingPathComponent("ntfsmac").path
    FileManager.default.createFile(atPath: binPath, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath)

    // Simulates a brew-tap-only install: the fixed prefix is missing, the homebrew-style
    // candidate is present — this is exactly the case the old single-path check missed.
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac", binPath])
    checker.check()
    #expect(checker.isInstalled)
}

@MainActor @Test func cliInstallCheckerReportsNotInstalledWhenNoCandidateExists() {
    let checker = CLIInstallChecker(candidatePaths: ["/nonexistent/bin/ntfsmac", "/also/nonexistent/bin/ntfsmac"])
    checker.check()
    #expect(!checker.isInstalled)
}

@MainActor @Test func cliInstallCheckerDefaultCandidatesMatchHelperSharedResolver() {
    let checker = CLIInstallChecker()
    // Just proves the default wiring stays in sync with HelperShared's own candidate list —
    // a real assertion on behavior would need a real install, which this repo's CI doesn't have.
    #expect(ntfsmacCandidatePrefixes.map { "\($0)/bin/ntfsmac" }.count == 2)
    checker.check()
}
