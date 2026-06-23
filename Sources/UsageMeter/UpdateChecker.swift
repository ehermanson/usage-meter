import AppKit
import Observation

/// Checks GitHub Releases for a newer build and, when one exists, surfaces a
/// one-click link to its download. This is the lightweight "tell me there's an
/// update" path — it opens the `.dmg` in the browser rather than swapping the
/// app in place. The repo is public, so the API call needs no auth.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Set when a release newer than the running bundle is published. `url` is the
    /// `.dmg` asset if one exists, otherwise the release page.
    private(set) var availableUpdate: (version: String, url: URL)?
    private(set) var isChecking = false

    private let latestReleaseURL = URL(
        string: "https://api.github.com/repos/ehermanson/usage-meter/releases/latest")!

    /// The running app's marketing version (CFBundleShortVersionString), e.g. "1.2.0".
    private let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// Hit GitHub at most once per hour; the menu reads the cached result. A manual
    /// re-check (force) bypasses the throttle.
    private var lastCheck: Date?

    func check(force: Bool = false) async {
        if isChecking { return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < 3600 { return }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            lastCheck = Date()

            let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            guard Self.isNewer(latest, than: currentVersion) else {
                availableUpdate = nil
                return
            }

            let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }
            let target =
                dmg.flatMap { URL(string: $0.browserDownloadURL) }
                ?? URL(string: release.htmlURL)
            if let target {
                availableUpdate = (version: latest, url: target)
            }
        } catch {
            // Network hiccups are non-fatal: just leave the cached state untouched.
        }
    }

    func openDownload() {
        guard let url = availableUpdate?.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Numeric, component-wise semver compare. Missing components count as 0, so
    /// "1.3" reads as "1.3.0". Non-numeric pre-release suffixes are ignored.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}
