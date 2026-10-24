import Foundation

/// Value type describing an available release asset from GitHub.
public struct ReleaseUpdateInfo: Equatable, Sendable, Codable {
    public let tagName: String
    public let version: String
    public let build: String
    public let dmgURL: URL
    public let assetSize: Int64
    public let releaseNotes: String
    public let publishedAt: Date?
    public let signatureURL: URL?
    public let signatureData: Data?

    public init(
        tagName: String,
        version: String? = nil,
        build: String? = nil,
        dmgURL: URL,
        assetSize: Int64,
        releaseNotes: String,
        publishedAt: Date? = nil,
        signatureURL: URL? = nil,
        signatureData: Data? = nil
    ) {
        self.tagName = tagName
        let (parsedVersion, parsedBuild) = Self.parseTag(tagName)
        self.version = version ?? parsedVersion
        self.build = build ?? parsedBuild
        self.dmgURL = dmgURL
        self.assetSize = assetSize
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.signatureURL = signatureURL
        self.signatureData = signatureData
    }

    /// Parses tags such as `v2.4.0` or `v2.3.040926`.
    private static func parseTag(_ tag: String) -> (version: String, build: String) {
        let raw = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = raw.split(separator: ".").map(String.init)
        if parts.count == 3 {
            let last = parts[2]
            // If the last component is a 6-digit date build (e.g. 040926)
            if last.count == 6, Int(last) != nil {
                return (version: "\(parts[0]).\(parts[1])", build: last)
            }
            return (version: raw, build: last)
        } else if parts.count == 2 {
            return (version: raw, build: parts[1])
        }
        return (version: raw, build: raw)
    }

    /// Returns true if this release is strictly newer than the given product version.
    public func isNewer(than productVersion: ProductVersion) -> Bool {
        let currentReleaseComponents = productVersion.release.split(separator: ".").compactMap { Int($0) }
        let newReleaseComponents = version.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(currentReleaseComponents.count, newReleaseComponents.count)
        for i in 0..<maxCount {
            let current = i < currentReleaseComponents.count ? currentReleaseComponents[i] : 0
            let new = i < newReleaseComponents.count ? newReleaseComponents[i] : 0
            if new > current { return true }
            if new < current { return false }
        }

        // If release numbers match, compare build identifiers
        return isBuildNewer(newBuild: build, currentBuild: productVersion.build)
    }

    private func isBuildNewer(newBuild: String, currentBuild: String) -> Bool {
        guard newBuild != currentBuild else { return false }

        // If both are 6-digit DDMMYY builds (e.g. 040926)
        if newBuild.count == 6, currentBuild.count == 6,
           let newDay = Int(newBuild.prefix(2)),
           let newMonth = Int(newBuild.dropFirst(2).prefix(2)),
           let newYear = Int(newBuild.suffix(2)),
           let curDay = Int(currentBuild.prefix(2)),
           let curMonth = Int(currentBuild.dropFirst(2).prefix(2)),
           let curYear = Int(currentBuild.suffix(2)) {
            if newYear != curYear { return newYear > curYear }
            if newMonth != curMonth { return newMonth > curMonth }
            return newDay > curDay
        }

        // If numeric build numbers
        if let newInt = Int(newBuild), let curInt = Int(currentBuild) {
            return newInt > curInt
        }

        return newBuild.compare(currentBuild, options: .numeric) == .orderedDescending
    }
}
