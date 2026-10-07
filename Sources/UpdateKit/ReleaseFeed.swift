import Foundation

/// The parts of a GitHub release (REST API, `releases/latest`) the updater needs.
public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
        case htmlURL = "html_url"
    }
}

/// A release the app could install.
public struct UpdateOffer: Sendable, Equatable {
    public let version: AppVersion
    public let title: String
    public let notes: String
    public let pageURL: URL
    public let archiveURL: URL
    public let archiveSize: Int64
    /// Ed25519 signature of the archive. Without it the app can only point to the release page.
    public let signatureURL: URL?

    public init(version: AppVersion, title: String, notes: String, pageURL: URL, archiveURL: URL, archiveSize: Int64, signatureURL: URL?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.archiveURL = archiveURL
        self.archiveSize = archiveSize
        self.signatureURL = signatureURL
    }
}

public enum ReleaseFeed {
    /// Release files are named "MiSTer-FTP-<version>.zip", with "<archive>.sig" beside them.
    public static let archivePrefix = "MiSTer-FTP-"

    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    /// Nil when the release is a draft or pre-release, or has no app archive.
    public static func offer(from release: GitHubRelease) -> UpdateOffer? {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName) else { return nil }
        let archives = release.assets.filter { $0.name.hasPrefix(archivePrefix) && $0.name.hasSuffix(".zip") }
        guard let archive = archives.first(where: { $0.name == "\(archivePrefix)\(version).zip" }) ?? archives.first else { return nil }
        let signature = release.assets.first { $0.name == archive.name + ".sig" }
        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateOffer(
            version: version,
            title: (title?.isEmpty ?? true) ? release.tagName : title!,
            notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            pageURL: release.htmlURL,
            archiveURL: archive.browserDownloadURL,
            archiveSize: archive.size,
            signatureURL: signature?.browserDownloadURL
        )
    }

    /// Asks the release API for the newest release. Nil when the repository has none.
    public static func fetchLatest(from url: URL, userAgent: String, session: URLSession = .shared) async throws -> GitHubRelease? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut, .dnsLookupFailed].contains(error.code) {
            throw UpdateError.offline
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil }
            if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
            guard (200..<300).contains(http.statusCode) else { throw UpdateError.server(http.statusCode) }
        }
        do {
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.badResponse
        }
    }

    /// Release files must come over HTTPS. Plain HTTP is allowed only from this Mac, for tests.
    public static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http":
            guard let host = url.host else { return false }
            return ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
        case "file":
            return ["127.0.0.1", "localhost", "::1", ""].contains((url.host ?? "").lowercased())
        default: return false
        }
    }
}
