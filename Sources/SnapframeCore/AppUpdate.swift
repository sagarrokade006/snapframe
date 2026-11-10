import Foundation

/// A dotted numeric version. `1.2` and `1.2.0` compare as equal.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Accepts `1.2.3` or `v1.2.3`. Pre-release tags such as `1.2-beta` are rejected.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        components = numbers
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String {
        (components + Array(repeating: 0, count: max(0, 3 - components.count))).map(String.init).joined(separator: ".")
    }
}

public struct AvailableRelease: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let downloadURL: URL
    public let size: Int

    public init(version: AppVersion, notes: String, downloadURL: URL, size: Int) {
        self.version = version
        self.notes = notes
        self.downloadURL = downloadURL
        self.size = size
    }
}

public enum ReleaseFeedError: LocalizedError, Equatable {
    case invalidVersion(String)
    case missingDiskImage
    case untrustedDownload

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let tag): return "The release tag “\(tag)” is not a version number, such as v1.2.0."
        case .missingDiskImage: return "The latest GitHub release has no DMG attached."
        case .untrustedDownload: return "The DMG link does not point to this app's GitHub releases."
        }
    }
}

/// Reads the response of GitHub's `releases/latest` endpoint.
public enum ReleaseFeed {
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }

        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    public static func downloadPrefix(repository: String) -> String {
        "https://github.com/\(repository)/releases/download/"
    }

    /// `requiredPrefix` stops a tampered response from pointing the app somewhere else.
    public static func parse(_ data: Data, requiredPrefix: String?) throws -> AvailableRelease {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name) else {
            throw ReleaseFeedError.invalidVersion(payload.tag_name)
        }
        guard let asset = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            throw ReleaseFeedError.missingDiskImage
        }
        if let requiredPrefix, !asset.browser_download_url.absoluteString.hasPrefix(requiredPrefix) {
            throw ReleaseFeedError.untrustedDownload
        }
        return AvailableRelease(
            version: version,
            notes: payload.body ?? "",
            downloadURL: asset.browser_download_url,
            size: asset.size
        )
    }
}
