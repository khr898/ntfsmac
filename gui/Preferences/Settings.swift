import Foundation
import ServiceManagement
import CFNetwork

public enum LaunchAtLoginRegistrationStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

public enum ProxyMode: String, CaseIterable, Sendable {
    case direct = "Direct"
    case system = "System"
    case custom = "Custom"
}

/// Seam over `SMAppService.mainApp` (macOS 13+, matches L7's floor — not the deprecated
/// `SMLoginItemSetEnabled`) so a toggled-on "Launch at login" preference actually registers the
/// login item rather than just persisting a bool nothing acts on, which would be a silently
/// broken control, not a deferred-integration gap.
public protocol LaunchAtLoginService: Sendable {
    func setEnabled(_ enabled: Bool) throws
}

/// Optional status capability kept separate from `LaunchAtLoginService` so existing service
/// conformers remain source compatible.
public protocol LaunchAtLoginStatusProviding: LaunchAtLoginService {
    var status: LaunchAtLoginRegistrationStatus { get }
}

public struct RealLaunchAtLoginService: LaunchAtLoginStatusProviding {
    public init() {}

    public var status: LaunchAtLoginRegistrationStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

private enum LaunchAtLoginUpdateResult: Sendable {
    case success(LaunchAtLoginRegistrationStatus)
    case failure(message: String, status: LaunchAtLoginRegistrationStatus)
}

/// Preference state backed by the real Service Management registration. `UserDefaults` mirrors
/// confirmed state and remains the fallback for injected legacy services that cannot report
/// status.
@MainActor
public final class Settings: ObservableObject {
    @Published public var launchAtLogin: Bool {
        didSet {
            guard !isApplyingLaunchAtLoginStatus else { return }
            beginLaunchAtLoginUpdate(launchAtLogin)
        }
    }
    @Published public var preservePrivateRelay: Bool {
        didSet {
            defaults.set(preservePrivateRelay, forKey: Keys.preservePrivateRelay)
        }
    }
    @Published public var proxyMode: ProxyMode {
        didSet {
            defaults.set(proxyMode.rawValue, forKey: Keys.proxyMode)
            syncProxyToConfigFile()
        }
    }
    @Published public var customProxyURL: String {
        didSet {
            defaults.set(customProxyURL, forKey: Keys.customProxyURL)
            if proxyMode == .custom {
                syncProxyToConfigFile()
            }
        }
    }
    @Published public private(set) var detectedSystemProxy: String?
    @Published public private(set) var isUpdatingLaunchAtLogin = false
    @Published public private(set) var launchAtLoginMessage: String?

    private let defaults: UserDefaults
    private let loginService: any LaunchAtLoginService
    private let configFileURL: URL?
    private var confirmedLaunchAtLogin: Bool
    private var isApplyingLaunchAtLoginStatus = false

    public init(
        defaults: UserDefaults = .standard,
        loginService: any LaunchAtLoginService = RealLaunchAtLoginService(),
        configFileURL: URL? = nil
    ) {
        self.defaults = defaults
        self.loginService = loginService
        self.configFileURL = configFileURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".anylinuxfs/config.toml")

        let persisted = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? Defaults.launchAtLogin
        let registrationStatus = Self.registrationStatus(for: loginService, fallbackEnabled: persisted)
        let initialValue = registrationStatus == .enabled

        launchAtLogin = initialValue
        confirmedLaunchAtLogin = initialValue
        launchAtLoginMessage = Self.message(for: registrationStatus)
        defaults.set(initialValue, forKey: Keys.launchAtLogin)

        preservePrivateRelay = defaults.object(forKey: Keys.preservePrivateRelay) as? Bool ?? Defaults.preservePrivateRelay

        if let rawMode = defaults.string(forKey: Keys.proxyMode), let mode = ProxyMode(rawValue: rawMode) {
            proxyMode = mode
        } else {
            proxyMode = Defaults.proxyMode
        }
        customProxyURL = defaults.string(forKey: Keys.customProxyURL) ?? Defaults.customProxyURL
        detectedSystemProxy = Self.detectSystemProxy()
    }

    /// Updates the real Service Management registration and then reads it back. The explicit
    /// method powers the UI while the original writable `launchAtLogin` property remains supported
    /// for existing callers.
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else { return }
        setPublishedLaunchAtLogin(enabled)
        beginLaunchAtLoginUpdate(enabled)
    }

    /// Reconciles changes made directly in System Settings while the app remains running.
    public func refreshLaunchAtLoginStatus() {
        guard !isUpdatingLaunchAtLogin,
              let statusProvider = loginService as? any LaunchAtLoginStatusProviding else { return }
        applyLaunchAtLoginStatus(statusProvider.status)
    }

    private func beginLaunchAtLoginUpdate(_ enabled: Bool) {
        guard !isUpdatingLaunchAtLogin else {
            setPublishedLaunchAtLogin(confirmedLaunchAtLogin)
            return
        }
        guard enabled != confirmedLaunchAtLogin else {
            setPublishedLaunchAtLogin(confirmedLaunchAtLogin)
            return
        }

        if enabled,
           let statusProvider = loginService as? any LaunchAtLoginStatusProviding,
           statusProvider.status == .requiresApproval {
            applyLaunchAtLoginStatus(.requiresApproval)
            return
        }

        setPublishedLaunchAtLogin(enabled)
        launchAtLoginMessage = nil
        isUpdatingLaunchAtLogin = true

        let loginService = self.loginService
        let confirmedBeforeUpdate = confirmedLaunchAtLogin
        Task { [weak self] in
            // `register`/`unregister` are blocking IPC calls. Keep them off the main actor and
            // Swift's cooperative executor, then reconcile the framework's actual status.
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    try loginService.setEnabled(enabled)
                    return LaunchAtLoginUpdateResult.success(
                        Self.registrationStatus(for: loginService, fallbackEnabled: enabled)
                    )
                } catch {
                    return LaunchAtLoginUpdateResult.failure(
                        message: error.localizedDescription,
                        status: Self.registrationStatus(
                            for: loginService,
                            fallbackEnabled: confirmedBeforeUpdate
                        )
                    )
                }
            }.value

            guard let self else { return }
            switch result {
            case .success(let status):
                self.applyLaunchAtLoginStatus(status)
            case .failure(let message, let status):
                self.applyLaunchAtLoginStatus(status, failureMessage: message)
            }
        }
    }

    private func applyLaunchAtLoginStatus(
        _ status: LaunchAtLoginRegistrationStatus,
        failureMessage: String? = nil
    ) {
        let enabled = status == .enabled
        confirmedLaunchAtLogin = enabled
        setPublishedLaunchAtLogin(enabled)
        launchAtLoginMessage = failureMessage.map { "Could not update Launch at login: \($0)" }
            ?? Self.message(for: status)
        isUpdatingLaunchAtLogin = false
        defaults.set(enabled, forKey: Keys.launchAtLogin)
    }

    private func setPublishedLaunchAtLogin(_ enabled: Bool) {
        isApplyingLaunchAtLoginStatus = true
        launchAtLogin = enabled
        isApplyingLaunchAtLoginStatus = false
    }

    private nonisolated static func registrationStatus(
        for service: any LaunchAtLoginService,
        fallbackEnabled: Bool
    ) -> LaunchAtLoginRegistrationStatus {
        if let statusProvider = service as? any LaunchAtLoginStatusProviding {
            return statusProvider.status
        }
        return fallbackEnabled ? .enabled : .disabled
    }

    private nonisolated static func message(
        for status: LaunchAtLoginRegistrationStatus
    ) -> String? {
        switch status {
        case .disabled, .enabled:
            return nil
        case .requiresApproval:
            return "Allow ntfsmac in System Settings > General > Login Items."
        case .unavailable:
            return "Launch at login is unavailable for this app bundle."
        }
    }

    public var effectiveProxyURL: String? {
        switch proxyMode {
        case .direct:
            return nil
        case .system:
            return detectedSystemProxy
        case .custom:
            let trimmed = customProxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public func refreshSystemProxy() {
        detectedSystemProxy = Self.detectSystemProxy()
        if proxyMode == .system {
            syncProxyToConfigFile()
        }
    }

    public func syncProxyToConfigFile() {
        guard let configFileURL else { return }
        try? Self.updateConfigFile(at: configFileURL, proxy: effectiveProxyURL)
    }

    public static func detectSystemProxy() -> String? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        if let httpEnable = settings[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnable == 1,
           let host = settings[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = settings[kCFNetworkProxiesHTTPPort as String] as? Int {
            return "http://\(host):\(port)"
        }
        if let httpsEnable = settings[kCFNetworkProxiesHTTPSEnable as String] as? Int, httpsEnable == 1,
           let host = settings[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = settings[kCFNetworkProxiesHTTPSPort as String] as? Int {
            return "http://\(host):\(port)"
        }
        if let socksEnable = settings[kCFNetworkProxiesSOCKSEnable as String] as? Int, socksEnable == 1,
           let host = settings[kCFNetworkProxiesSOCKSProxy as String] as? String,
           let port = settings[kCFNetworkProxiesSOCKSPort as String] as? Int {
            return "socks5://\(host):\(port)"
        }
        return nil
    }

    public static func updateConfigFile(at url: URL, proxy: String?) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if content.isEmpty && (proxy == nil || proxy?.isEmpty == true) {
            return
        }

        if let proxy = proxy, !proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sanitized = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.contains("[network]") {
                let lines = content.components(separatedBy: "\n")
                var newLines: [String] = []
                var inNetwork = false
                var replaced = false
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") {
                        if inNetwork && !replaced {
                            newLines.append("proxy = \"\(sanitized)\"")
                            replaced = true
                        }
                        inNetwork = (trimmed == "[network]")
                        newLines.append(line)
                    } else if inNetwork && trimmed.hasPrefix("proxy") && trimmed.contains("=") {
                        newLines.append("proxy = \"\(sanitized)\"")
                        replaced = true
                    } else {
                        newLines.append(line)
                    }
                }
                if inNetwork && !replaced {
                    newLines.append("proxy = \"\(sanitized)\"")
                }
                content = newLines.joined(separator: "\n")
            } else {
                if !content.isEmpty && !content.hasSuffix("\n") {
                    content += "\n"
                }
                content += "\n[network]\nproxy = \"\(sanitized)\"\n"
            }
        } else {
            if content.contains("[network]") {
                let lines = content.components(separatedBy: "\n")
                var newLines: [String] = []
                var inNetwork = false
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[") {
                        inNetwork = (trimmed == "[network]")
                        newLines.append(line)
                    } else if inNetwork && trimmed.hasPrefix("proxy") && trimmed.contains("=") {
                        // skip
                    } else {
                        newLines.append(line)
                    }
                }
                content = newLines.joined(separator: "\n")
            }
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// GUI-PLAN.md "Settings page" table's literal Default column.
    public enum Defaults {
        public static let launchAtLogin = false
        public static let preservePrivateRelay = false
        public static let proxyMode = ProxyMode.direct
        public static let customProxyURL = ""
    }

    private enum Keys {
        static let launchAtLogin = "com.khr898.ntfsmac.settings.launchAtLogin"
        static let preservePrivateRelay = "com.khr898.ntfsmac.settings.preservePrivateRelay"
        static let proxyMode = "com.khr898.ntfsmac.settings.proxyMode"
        static let customProxyURL = "com.khr898.ntfsmac.settings.customProxyURL"
    }
}
