import Foundation
import ServiceManagement

/// Seam over `SMAppService.mainApp` (macOS 13+, matches L7's floor — not the deprecated
/// `SMLoginItemSetEnabled`) so a toggled-on "Launch at login" preference actually registers the
/// login item rather than just persisting a bool nothing acts on, which would be a silently
/// broken control, not a deferred-integration gap.
public protocol LaunchAtLoginService: Sendable {
    func setEnabled(_ enabled: Bool) throws
}

public struct RealLaunchAtLoginService: LaunchAtLoginService {
    public init() {}

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// GUI-PLAN.md "Preferences window" table, exactly these five controls — this unit's Don't
/// clause: no controls beyond this table. Persisted via `UserDefaults` (constructor-injected so
/// tests use an isolated suite, never the real `.standard` domain).
@MainActor
public final class Settings: ObservableObject {
    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            // ponytail: SMAppService.register/unregister is a blocking IPC call — same class of
            // call HelperInstaller.runOffCooperativePool avoids running on the main actor.
            let loginService = self.loginService
            let enabled = launchAtLogin
            Task.detached(priority: .userInitiated) {
                try? loginService.setEnabled(enabled)
            }
        }
    }
    @Published public var showSpeedInMenuBar: Bool {
        didSet { defaults.set(showSpeedInMenuBar, forKey: Keys.showSpeedInMenuBar) }
    }

    private let defaults: UserDefaults
    private let loginService: any LaunchAtLoginService

    public init(defaults: UserDefaults = .standard, loginService: any LaunchAtLoginService = RealLaunchAtLoginService()) {
        self.defaults = defaults
        self.loginService = loginService

        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? Defaults.launchAtLogin
        showSpeedInMenuBar = defaults.object(forKey: Keys.showSpeedInMenuBar) as? Bool ?? Defaults.showSpeedInMenuBar
    }

    /// GUI-PLAN.md "Preferences window" table's literal Default column.
    public enum Defaults {
        public static let launchAtLogin = false
        public static let showSpeedInMenuBar = false
    }

    private enum Keys {
        static let launchAtLogin = "com.khr898.ntfsmac.settings.launchAtLogin"
        static let showSpeedInMenuBar = "com.khr898.ntfsmac.settings.showSpeedInMenuBar"
    }
}
