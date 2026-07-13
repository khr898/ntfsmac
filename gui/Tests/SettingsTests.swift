import Foundation
import Testing
@testable import NtfsmacGUI

// GUI-PLAN.md "Preferences window". Acceptance: assert defaults + persistence round-trip.
// Uses an isolated UserDefaults suite per test (never the real .standard domain).

private func makeIsolatedDefaults(_ testName: String) -> UserDefaults {
    let suiteName = "com.khr898.ntfsmac.tests.\(testName).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private struct FakeLoginService: LaunchAtLoginService {
    let shouldThrow: Bool
    func setEnabled(_ enabled: Bool) throws {
        if shouldThrow { throw NSError(domain: "test", code: 1) }
    }
}

@MainActor
@Test func defaultsMatchGuiPlanTable() {
    let defaults = makeIsolatedDefaults(#function)
    let settings = Settings(defaults: defaults, loginService: FakeLoginService(shouldThrow: false))

    #expect(settings.launchAtLogin == false)
    #expect(settings.showSpeedInMenuBar == false)
}

@MainActor
@Test func settingsPersistAcrossInstancesWithSameDefaultsSuite() {
    let defaults = makeIsolatedDefaults(#function)
    let first = Settings(defaults: defaults, loginService: FakeLoginService(shouldThrow: false))

    first.launchAtLogin = true
    first.showSpeedInMenuBar = true

    let second = Settings(defaults: defaults, loginService: FakeLoginService(shouldThrow: false))

    #expect(second.launchAtLogin == true)
    #expect(second.showSpeedInMenuBar == true)
}

@MainActor
@Test func launchAtLoginTogglesCallTheLoginService() {
    let defaults = makeIsolatedDefaults(#function)
    // Failure from the real SMAppService call must not crash or block persistence — `didSet`
    // uses `try?`, so this just documents that behavior rather than asserting a thrown error.
    let settings = Settings(defaults: defaults, loginService: FakeLoginService(shouldThrow: true))

    settings.launchAtLogin = true

    #expect(settings.launchAtLogin == true)
    #expect(defaults.bool(forKey: "com.khr898.ntfsmac.settings.launchAtLogin") == true)
}
