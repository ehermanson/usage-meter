import AppKit
import Observation

/// What `UpdateChecker` found on GitHub: the new version plus where to get it.
/// `zipURL` feeds `UpdateInstaller`'s in-place install; `fallbackURL` is the
/// browser path (the `.dmg`, or the release page when no asset exists).
struct AvailableUpdate: Equatable {
    let version: String
    let zipURL: URL?
    let fallbackURL: URL
}

/// Checks GitHub Releases for a newer build and, when one exists, surfaces it
/// to the menu. The seamless path hands the notarized `.zip` to
/// `UpdateInstaller`; when that's not possible the menu falls back to opening
/// the `.dmg` in the browser. The repo is public, so the API call needs no auth.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// Set when a release newer than the running bundle is published.
    private(set) var availableUpdate: AvailableUpdate?
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

            let targets = Self.downloadTargets(
                assets: release.assets.map { ($0.name, $0.browserDownloadURL) },
                releasePage: release.htmlURL)
            if let targets {
                availableUpdate = AvailableUpdate(
                    version: latest, zipURL: targets.zip, fallbackURL: targets.fallback)
            }
        } catch {
            // Network hiccups are non-fatal: just leave the cached state untouched.
        }
    }

    func openDownload() {
        guard let url = availableUpdate?.fallbackURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Split a release's assets into the two download paths: the notarized app
    /// zip (in-place install) and a browser fallback (.dmg, else the release
    /// page). The zip is matched by exact name so a stray archive on the
    /// release (dSYMs.zip, symbols) can never reach the installer.
    nonisolated static func downloadTargets(
        assets: [(name: String, url: String)], releasePage: String
    ) -> (zip: URL?, fallback: URL)? {
        let zip = assets.first { $0.name == "UsageMeter.zip" }.flatMap { URL(string: $0.url) }
        let dmg = assets.first { $0.name.hasSuffix(".dmg") }.flatMap { URL(string: $0.url) }
        guard let fallback = dmg ?? URL(string: releasePage) else { return nil }
        return (zip, fallback)
    }

    /// True when two versions are numerically equal, so "1.3" matches "1.3.0".
    /// The installer uses this to confirm the unpacked bundle is the release
    /// it asked for.
    nonisolated static func isSameVersion(_ a: String, _ b: String) -> Bool {
        !isNewer(a, than: b) && !isNewer(b, than: a)
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
