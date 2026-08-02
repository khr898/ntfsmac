import Foundation
import Testing
@testable import NtfsmacGUI

private func makeGuardTestDirectory(_ testName: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ntfsmac-instance-tests-\(testName)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func aSecondGuiInstanceCannotAcquireTheSameLock() throws {
    let directory = try makeGuardTestDirectory(#function)
    let lockFile = directory.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try SingleInstanceGuard(lockFileURL: lockFile)

    #expect(throws: SingleInstanceGuardError.alreadyRunning) {
        try SingleInstanceGuard(lockFileURL: lockFile)
    }

    first.release()
}

@Test func releasingTheGuardIsIdempotentAndAllowsAReplacement() throws {
    let directory = try makeGuardTestDirectory(#function)
    let lockFile = directory.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try SingleInstanceGuard(lockFileURL: lockFile)
    first.release()
    first.release()

    let replacement = try SingleInstanceGuard(lockFileURL: lockFile)
    replacement.release()
}

@Test func aParentPathThatIsAFileIsRejected() throws {
    let directory = try makeGuardTestDirectory(#function)
    let parentFile = directory.appendingPathComponent("not-a-directory")
    let lockFile = parentFile.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data().write(to: parentFile)

    #expect(throws: SingleInstanceGuardError.self) {
        try SingleInstanceGuard(lockFileURL: lockFile)
    }
}

@Test func aDirectoryCannotBeUsedAsTheLockFile() throws {
    let directory = try makeGuardTestDirectory(#function)
    let lockFile = directory.appendingPathComponent("instance.lock")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: lockFile, withIntermediateDirectories: false)

    #expect(throws: SingleInstanceGuardError.self) {
        try SingleInstanceGuard(lockFileURL: lockFile)
    }
}

@Test func errorsHavePlainLanguageDescriptions() {
    #expect(SingleInstanceGuardError.alreadyRunning.errorDescription?.contains("already running") == true)
    #expect(SingleInstanceGuardError.unavailable("permission denied").errorDescription?.contains("permission denied") == true)
}

@Test func defaultLockPathUsesTheUserApplicationSupportDirectory() {
    let url = SingleInstanceGuard.defaultLockFileURL()

    #expect(url.lastPathComponent == "gui-instance.lock")
    #expect(url.deletingLastPathComponent().lastPathComponent == "ntfsmac")
}
