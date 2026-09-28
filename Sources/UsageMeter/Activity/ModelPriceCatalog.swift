import Foundation

/// Where the Cost tab's prices come from: LiteLLM's public table, cached on
/// disk and refreshed at most daily, over a bundled snapshot that makes the
/// first launch (and every offline one) work.
///
/// Prices change rarely and a stale table only skews an estimate, so every
/// failure — no network, a timeout, a malformed download — quietly keeps
/// whatever was already in use.
enum ModelPriceCatalog {
    static let sourceURL = URL(
        string:
            "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    static let maxAge: TimeInterval = 24 * 3600
    static let downloadTimeout: TimeInterval = 20

    /// Ephemeral, so the 3 MB body isn't also kept in the shared URL cache,
    /// and bounded end to end rather than only between packets.
    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = downloadTimeout
        config.timeoutIntervalForResource = downloadTimeout
        return URLSession(configuration: config)
    }()

    static var cacheFile: URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.erichermanson.usagemeter"
        return caches.appendingPathComponent(bundleID).appendingPathComponent("model-prices.json")
    }

    /// The best table available without the network: the cached download
    /// layered over the bundled snapshot, or the snapshot alone.
    static func loadCached(from file: URL = cacheFile) -> PricingTable {
        guard let data = try? Data(contentsOf: file),
            let cached = PricingTable.parseLiteLLM(
                data, source: .downloaded(modified(file) ?? .now))
        else { return .bundled }
        return PricingTable.bundled.overlaying(cached)
    }

    /// Whether the cached copy is missing or older than a day.
    static func needsRefresh(file: URL = cacheFile, now: Date = .now) -> Bool {
        guard let modified = modified(file) else { return true }
        return now.timeIntervalSince(modified) >= maxAge
    }

    /// Downloads a fresh table if the cache is due, and returns it layered
    /// over the bundle; nil when nothing changed (not due, or the fetch
    /// failed). Only a download that parses into a usable table replaces the
    /// cache, so a truncated or error response can't clobber a good copy.
    static func refreshIfNeeded(
        file: URL = cacheFile, now: Date = .now, session: URLSession = downloadSession
    ) async -> PricingTable? {
        guard needsRefresh(file: file, now: now) else { return nil }
        let request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData)
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let table = PricingTable.parseLiteLLM(data, source: .downloaded(.now))
        else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            // Still use what was fetched; it just won't outlive this launch.
        }
        return PricingTable.bundled.overlaying(table)
    }

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate]
            as? Date
    }
}
