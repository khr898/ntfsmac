import Foundation

public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(ReleaseUpdateInfo)
    case downloading(progress: Double)
    case extracting
    case readyToRestart(stagedAppURL: URL, version: String)
    case failed(String)
}

@MainActor
public final class AppUpdateController: ObservableObject {
    @Published public private(set) var state: UpdateState = .idle

    private let checkService: any ReleaseChecking
    private let downloadService: any UpdateDownloading
    private let extractionService: any UpdateExtracting
    private let relaunchService: any AppRelaunching
    private let productVersionProvider: () -> ProductVersion
    private let targetAppURL: URL

    public init(
        checkService: any ReleaseChecking = GitHubReleaseCheckService(),
        downloadService: any UpdateDownloading = RealUpdateDownloadService(),
        extractionService: any UpdateExtracting = RealUpdateExtractionService(),
        relaunchService: any AppRelaunching = RealAppRelaunchService(),
        productVersionProvider: @escaping () -> ProductVersion = { ProductVersion.current() },
        targetAppURL: URL = Bundle.main.bundleURL
    ) {
        self.checkService = checkService
        self.downloadService = downloadService
        self.extractionService = extractionService
        self.relaunchService = relaunchService
        self.productVersionProvider = productVersionProvider
        self.targetAppURL = targetAppURL
    }

    public func checkForUpdates() async {
        guard state != .checking else { return }
        state = .checking
        do {
            let current = productVersionProvider()
            if let update = try await checkService.checkForUpdates(currentVersion: current) {
                state = .updateAvailable(update)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    public func downloadAndPrepare() async {
        guard case .updateAvailable(let info) = state else { return }
        state = .downloading(progress: 0.0)

        do {
            var signatureData = info.signatureData
            if signatureData == nil, let sigURL = info.signatureURL {
                let sigFileURL = try await downloadService.download(from: sigURL) { _ in }
                signatureData = try? Data(contentsOf: sigFileURL)
                try? FileManager.default.removeItem(at: sigFileURL)
            }

            let dmgURL = try await downloadService.download(from: info.dmgURL) { [weak self] progress in
                Task { @MainActor in
                    self?.state = .downloading(progress: progress)
                }
            }

            state = .extracting
            let stagedApp = try await extractionService.extractAndValidate(dmgURL: dmgURL, signatureData: signatureData)
            state = .readyToRestart(stagedAppURL: stagedApp, version: info.version)
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    public func restartAndApply(hasActiveMounts: Bool) {
        guard case .readyToRestart(let stagedAppURL, _) = state else { return }

        guard !hasActiveMounts else {
            state = .failed("Please unmount active drives before restarting.")
            return
        }

        do {
            try relaunchService.relaunchAndSwap(
                stagedAppURL: stagedAppURL,
                targetAppURL: targetAppURL,
                hasActiveMounts: false
            )
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    public func reset() {
        state = .idle
    }

    func forceStateForTesting(_ newState: UpdateState) {
        self.state = newState
    }

    private static func describe(_ error: Error) -> String {
        if let checkError = error as? ReleaseCheckError {
            switch checkError {
            case .badHTTPStatus(let code):
                return "GitHub release server returned error HTTP \(code)."
            case .missingDMGAsset:
                return "The release does not contain a macOS application package."
            case .untrustedDownloadHost(let host):
                return "Download URL host '\(host)' is not trusted."
            case .invalidResponse:
                return "Received invalid response from release server."
            }
        }
        if let extractError = error as? UpdateExtractionError {
            switch extractError {
            case .mountFailed(let out):
                return "Failed to mount update image: \(out)"
            case .bundleNotFound:
                return "The update disk image is missing ntfsmac.app."
            case .invalidBundleStructure(let reason):
                return "Update verification failed: \(reason)"
            case .codeSignatureInvalid:
                return "Update code signature verification failed."
            case .signatureVerificationFailed(let reason):
                return "Update cryptographic signature verification failed: \(reason)"
            case .extractionFailed(let reason):
                return "Failed to extract update: \(reason)"
            }
        }
        if let relaunchError = error as? AppRelaunchError {
            switch relaunchError {
            case .activeMountsPresent:
                return "Please unmount active drives before restarting."
            case .stagedAppNotFound:
                return "The staged update bundle could not be found."
            case .swapScriptFailed(let reason):
                return "Failed to launch update installer: \(reason)"
            }
        }
        return error.localizedDescription
    }
}
