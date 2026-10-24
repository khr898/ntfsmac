import Foundation
import Testing
import SwiftUI
@testable import NtfsmacGUI

private func makeIsolatedDefaults(_ testName: String) -> UserDefaults {
    let suiteName = "com.khr898.ntfsmac.tests.\(testName).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private final class DummyLoginService: LaunchAtLoginStatusProviding, @unchecked Sendable {
    var status: LaunchAtLoginRegistrationStatus { .disabled }
    func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
@Test func proxySettingsDefaultToDirectAndPersist() throws {
    let defaults = makeIsolatedDefaults(#function)
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configFileURL = tempDir.appendingPathComponent("config.toml")
    let settings = Settings(defaults: defaults, loginService: DummyLoginService(), configFileURL: configFileURL)

    #expect(settings.proxyMode == .direct)
    #expect(settings.customProxyURL == "")
    #expect(settings.effectiveProxyURL == nil)

    settings.customProxyURL = "http://127.0.0.1:7890"
    settings.proxyMode = .custom

    #expect(settings.proxyMode == .custom)
    #expect(settings.effectiveProxyURL == "http://127.0.0.1:7890")
    #expect(defaults.string(forKey: "com.khr898.ntfsmac.settings.proxyMode") == ProxyMode.custom.rawValue)
    #expect(defaults.string(forKey: "com.khr898.ntfsmac.settings.customProxyURL") == "http://127.0.0.1:7890")

    let savedContent = try String(contentsOf: configFileURL, encoding: .utf8)
    #expect(savedContent.contains("[network]"))
    #expect(savedContent.contains("proxy = \"http://127.0.0.1:7890\""))

    // Reload settings from isolated defaults
    let reloaded = Settings(defaults: defaults, loginService: DummyLoginService(), configFileURL: configFileURL)
    #expect(reloaded.proxyMode == .custom)
    #expect(reloaded.customProxyURL == "http://127.0.0.1:7890")
    #expect(reloaded.effectiveProxyURL == "http://127.0.0.1:7890")
}

@MainActor
@Test func updateConfigFileHandlesAddUpdateAndRemoval() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configFileURL = tempDir.appendingPathComponent("config.toml")

    // 1. Initial write
    let initialConfig = """
    [network]
    helper = "vmnet"

    [alpine]
    custom_packages = ["git"]
    """
    try initialConfig.write(to: configFileURL, atomically: true, encoding: .utf8)

    // 2. Add proxy
    try Settings.updateConfigFile(at: configFileURL, proxy: "http://127.0.0.1:7890")
    var content = try String(contentsOf: configFileURL, encoding: .utf8)
    #expect(content.contains("proxy = \"http://127.0.0.1:7890\""))
    #expect(content.contains("[alpine]"))
    #expect(content.contains("custom_packages = [\"git\"]"))

    // 3. Update proxy
    try Settings.updateConfigFile(at: configFileURL, proxy: "http://10.0.0.1:8080")
    content = try String(contentsOf: configFileURL, encoding: .utf8)
    #expect(!content.contains("127.0.0.1:7890"))
    #expect(content.contains("proxy = \"http://10.0.0.1:8080\""))
    #expect(content.contains("custom_packages = [\"git\"]"))

    // 4. Remove proxy (switch to direct)
    try Settings.updateConfigFile(at: configFileURL, proxy: nil)
    content = try String(contentsOf: configFileURL, encoding: .utf8)
    #expect(!content.contains("proxy ="))
    #expect(content.contains("helper = \"vmnet\""))
    #expect(content.contains("[alpine]"))
}

@MainActor
@Test func effectiveProxyURLReturnsNilWhenCustomURLIsEmpty() throws {
    let defaults = makeIsolatedDefaults(#function)
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configFileURL = tempDir.appendingPathComponent("config.toml")
    let settings = Settings(defaults: defaults, loginService: DummyLoginService(), configFileURL: configFileURL)

    settings.proxyMode = .custom
    settings.customProxyURL = "   "
    #expect(settings.effectiveProxyURL == nil)

    // Config file should not have proxy = "   "
    if FileManager.default.fileExists(atPath: configFileURL.path) {
        let content = try String(contentsOf: configFileURL, encoding: .utf8)
        #expect(!content.contains("proxy ="))
    }
}

@MainActor
@Test func updateConfigFileCreatesNewFileIfMissing() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let configFileURL = tempDir.appendingPathComponent("sub/dir/config.toml")
    try Settings.updateConfigFile(at: configFileURL, proxy: "http://proxy.corp.internal:3128")

    #expect(FileManager.default.fileExists(atPath: configFileURL.path))
    let content = try String(contentsOf: configFileURL, encoding: .utf8)
    #expect(content.contains("[network]"))
    #expect(content.contains("proxy = \"http://proxy.corp.internal:3128\""))
}

@MainActor
@Test func preferencesViewRendersWithAllProxyModes() throws {
    let defaults = makeIsolatedDefaults(#function)
    let settings = Settings(defaults: defaults, loginService: DummyLoginService())

    for mode in ProxyMode.allCases {
        settings.proxyMode = mode
        if mode == .custom {
            settings.customProxyURL = "http://127.0.0.1:7890"
        }
        let view = PreferencesView(
            settings: settings,
            installer: HelperInstaller(),
            uninstaller: HelperUninstaller(),
            onBack: {},
            productVersion: ProductVersion(release: "4.0", build: "241026")
        )
        let renderer = ImageRenderer(content: view)
        #expect(renderer.nsImage?.size.width == 320)
        #expect((renderer.nsImage?.size.height ?? 0) > 200)
    }
}
