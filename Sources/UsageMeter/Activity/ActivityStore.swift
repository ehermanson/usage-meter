import Foundation
import Observation

/// Backs the Tokens and Cost tabs: token use and API-equivalent cost over a
/// range, read from the session logs Claude Code and Codex keep locally.
///
/// Scanning is the slow part and happens off the main actor, incrementally
/// (see `ActivityScanner`). The records it yields are deduped once per scan,
/// also off the main actor, and kept here, so changing the range only
/// re-aggregates them — the scan always covers the widest range, and a
/// narrower one is a filter.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()

    /// Which window the tabs show. Persisted, and shared by both tabs so
    /// flipping between tokens and cost compares like with like.
    var range: ActivityRange = ActivityStore.loadRange() {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: Self.rangeKey)
            if range != oldValue { reaggregate() }
        }
    }

    /// Nil until the first scan completes.
    private(set) var summary: ActivitySummary?
    private(set) var lastScanned: Date?

    /// No scan yet, or the last is over a minute old. The logs only grow
    /// while a tool is in use, so this is about noticing new work on the
    /// next menu open — not about precision, which the scan always has.
    var isStale: Bool {
        guard let lastScanned else { return true }
        return Date.now.timeIntervalSince(lastScanned) >= Self.staleAfter
    }

    private static let rangeKey = "activityRange"
    private static let staleAfter: TimeInterval = 60
    /// How long a failed price download waits before trying again. Success
    /// is paced by the cache's own 24h age instead.
    private static let priceRetryInterval: TimeInterval = 3600

    @ObservationIgnored private let scanner: ActivityScanner
    /// Where downloaded prices are kept; see `ModelPriceCatalog`.
    @ObservationIgnored private let priceCache: URL
    /// The last scan's records, already deduped, and the providers it found.
    @ObservationIgnored private var scanned: Scanned?
    @ObservationIgnored private var pricing: PricingTable?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshToken = 0
    @ObservationIgnored private var priceAttempt: Date?
    @ObservationIgnored private var isFetchingPrices = false

    private struct Scanned {
        /// The scan's generation these came from; see `ActivityScanResult`.
        let generation: Int
        let records: [UsageRecord]
        let detected: Set<String>
    }

    /// The app uses `shared`. Tests build their own over temp logs, with a
    /// price cache of their own so a refresh can't reach the network or
    /// rewrite the app's cache.
    init(
        scanner: ActivityScanner = ActivityScanner(),
        priceCache: URL = ModelPriceCatalog.cacheFile
    ) {
        self.scanner = scanner
        self.priceCache = priceCache
    }

    private static func loadRange() -> ActivityRange {
        UserDefaults.standard.string(forKey: rangeKey).flatMap(ActivityRange.init(rawValue:))
            ?? .week
    }

    /// Scans for new log lines, then re-aggregates. Concurrent calls coalesce
    /// onto the in-flight scan, as `UsageStore.refresh` does; a forced call
    /// waits for it and then runs its own, so it sees anything written since.
    ///
    /// Forced calls that waited on the same scan share the one after it (a
    /// Refresh click and a Claude folder change, both behind the scan that
    /// opening the panel started): the first to resume starts it, and the
    /// rest join it, since it began after they asked too. So refreshes never
    /// overlap. Side by side, each would dedupe on its own and could finish
    /// in either order, leaving the earlier scan's records on screen.
    func refresh(force: Bool = false) async {
        if let task = refreshTask {
            await task.value
            if !force { return }
            if let next = refreshTask, next != task {
                await next.value
                return
            }
        }
        refreshToken &+= 1
        let myToken = refreshToken
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        if refreshToken == myToken { refreshTask = nil }
    }

    private func performRefresh() async {
        let scanner = scanner
        let priceCache = priceCache
        let loadPrices = pricing == nil
        let previous = scanned
        // Utility priority: this is background bookkeeping, and a cold scan
        // reads gigabytes — it shouldn't compete with anything the user is
        // looking at. (The scan itself runs on the scanner's own queue.)
        let (fresh, prices) = await Task.detached(priority: .utility) {
            let prices = loadPrices ? ModelPriceCatalog.loadCached(from: priceCache) : nil
            let result = await scanner.scan()
            // Deduped here, off the main actor and once per scan, so a range
            // change or a price refresh doesn't redo it. A warm scan that
            // found nothing new hands back the same records, which dedupe to
            // what they did last time.
            let records: [UsageRecord]
            if let previous, previous.generation == result.generation {
                records = previous.records
            } else {
                records = ActivityAggregator.dedupe(result.records)
            }
            let fresh = Scanned(
                generation: result.generation, records: records,
                detected: result.detectedProviders)
            return (fresh, prices)
        }.value
        if let prices { pricing = prices }
        scanned = fresh
        lastScanned = .now
        reaggregate()
        refreshPricesIfDue()
    }

    /// Rebuilds the summary from the deduped records. Synchronous: it's a
    /// filter and a sum over records already in memory, and doing it in
    /// line means a range change never shows the previous range's numbers.
    private func reaggregate() {
        guard let scanned else { return }
        summary = ActivityAggregator.summarize(
            deduped: scanned.records, range: range, now: .now, calendar: .current,
            pricing: pricing ?? .bundled, detected: scanned.detected)
    }

    /// Fetches fresh prices in the background when the cached table is over
    /// a day old, then re-prices what's shown. Failure changes nothing.
    private func refreshPricesIfDue() {
        guard !isFetchingPrices, ModelPriceCatalog.needsRefresh(file: priceCache) else { return }
        if let priceAttempt, Date.now.timeIntervalSince(priceAttempt) < Self.priceRetryInterval {
            return
        }
        isFetchingPrices = true
        priceAttempt = .now
        let priceCache = priceCache
        Task {
            let fresh = await Task.detached(priority: .utility) {
                await ModelPriceCatalog.refreshIfNeeded(file: priceCache)
            }.value
            isFetchingPrices = false
            guard let fresh else { return }
            pricing = fresh
            reaggregate()
        }
    }
}
