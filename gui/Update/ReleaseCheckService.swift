import Foundation

public protocol HTTPDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataLoading {}

public enum ReleaseCheckError: Error, Equatable, Sendable {
    case badHTTPStatus(Int)
    case missingDMGAsset
    case untrustedDownloadHost(String)
    case invalidResponse
}

public protocol ReleaseChecking: Sendable {
    func checkForUpdates(currentVersion: ProductVersion) async throws -> ReleaseUpdateInfo?
}

public struct GitHubReleaseCheckService: ReleaseChecking {
    private let endpointURL: URL
    private let loader: any HTTPDataLoading
    private static let trustedHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com",
        "api.github.com"
    ]

    public init(
        endpointURL: URL = URL(string: "https://api.github.com/repos/khr898/ntfsmac/releases/latest")!,
        loader: any HTTPDataLoading = URLSession.shared
    ) {
        self.endpointURL = endpointURL
        self.loader = loader
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let size: Int64
        let browser_download_url: String
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let published_at: String?
        let assets: [GitHubAsset]
    }

    public func checkForUpdates(currentVersion: ProductVersion) async throws -> ReleaseUpdateInfo? {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ntfsmac-updater", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReleaseCheckError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw ReleaseCheckError.badHTTPStatus(http.statusCode)
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

        // Locate DMG asset
        guard let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let downloadURL = URL(string: dmgAsset.browser_download_url)
        else {
            throw ReleaseCheckError.missingDMGAsset
        }

        // Locate companion cryptographic signature asset (.dmg.sig, .dmg.minisig, or .sig)
        let sigAsset = release.assets.first(where: {
            let lower = $0.name.lowercased()
            return lower.hasSuffix(".dmg.sig") || lower.hasSuffix(".dmg.minisig") || lower.hasSuffix(".sig")
        })
        let sigURL = sigAsset.flatMap { URL(string: $0.browser_download_url) }

        // Validate host
        guard let host = downloadURL.host?.lowercased(),
              Self.trustedHosts.contains(host) || Self.trustedHosts.contains(where: { host.hasSuffix("." + $0) })
        else {
            throw ReleaseCheckError.untrustedDownloadHost(downloadURL.host ?? "unknown")
        }

        let publishedDate: Date? = {
            guard let raw = release.published_at else { return nil }
            return ISO8601DateFormatter().date(from: raw)
        }()

        let updateInfo = ReleaseUpdateInfo(
            tagName: release.tag_name,
            dmgURL: downloadURL,
            assetSize: dmgAsset.size,
            releaseNotes: release.body ?? "",
            publishedAt: publishedDate,
            signatureURL: sigURL
        )

        return updateInfo.isNewer(than: currentVersion) ? updateInfo : nil
    }
}
