import Observation
import SwiftUI

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    var providers: [ProviderUsage] = []
    var isLoading = false
    var lastUpdated: Date?

    /// Which provider is pinned to the menu-bar title; nil = Auto (highest 5h).
    var pinnedProvider: String? = UserDefaults.standard.string(forKey: "pinnedProvider") {
        didSet { UserDefaults.standard.set(pinnedProvider, forKey: "pinnedProvider") }
    }

    /// Compact menu-bar title: show only the 5hr window, skip weekly.
    var compactMenuBar: Bool = UserDefaults.standard.bool(forKey: "compactMenuBar") {
        didSet { UserDefaults.standard.set(compactMenuBar, forKey: "compactMenuBar") }
    }

    /// Claude's usage endpoint is itself rate-limited and answers "throttled"
    /// when probed too often — so retrying hard only keeps it throttled. After a
    /// success we settle to `claudeSuccessInterval`; after a failure we back off
    /// exponentially from `claudeBackoffBase` up to `claudeBackoffMax` to give the
    /// endpoint room to recover instead of hammering it.
    private let claudeSuccessInterval: TimeInterval = 300
    private let claudeBackoffBase: TimeInterval = 180
    private let claudeBackoffMax: TimeInterval = 900
    private var claudeLastAttempt: Date?
    private var claudeFailureStreak = 0

    /// Last successful snapshots, shown when a refresh fails/throttles. Persisted
    /// across launches so a cold start (with a throttled endpoint) shows the last
    /// known values instead of a blank "no data" row.
    private var lastGoodClaude: ProviderUsage? { didSet { persistLastGood() } }
    private var lastGoodCodex: ProviderUsage? { didSet { persistLastGood() } }

    private enum PersistKey {
        static let claude = "lastGoodClaude.v1"
        static let codex = "lastGoodCodex.v1"
        static let updated = "lastGoodUpdated.v1"
    }

    /// Set while seeding from disk so the `didSet` hooks don't re-persist (and
    /// clobber the saved timestamp) during load.
    private var isLoadingPersisted = false

    private init() { loadLastGood() }

    /// Seed `lastGood*` and the visible rows from disk so the menu has data the
    /// instant it opens, before the first (possibly throttled) probe returns.
    private func loadLastGood() {
        isLoadingPersisted = true
        defer { isLoadingPersisted = false }
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: PersistKey.claude) {
            lastGoodClaude = try? decoder.decode(ProviderUsage.self, from: data)
        }
        if let data = defaults.data(forKey: PersistKey.codex) {
            lastGoodCodex = try? decoder.decode(ProviderUsage.self, from: data)
        }
        let seeded = [lastGoodClaude, lastGoodCodex].compactMap { $0 }
        if !seeded.isEmpty {
            providers = seeded
            lastUpdated = defaults.object(forKey: PersistKey.updated) as? Date
        }
    }

    private func persistLastGood() {
        guard !isLoadingPersisted else { return }
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        if let claude = lastGoodClaude, let data = try? encoder.encode(claude) {
            defaults.set(data, forKey: PersistKey.claude)
        }
        if let codex = lastGoodCodex, let data = try? encoder.encode(codex) {
            defaults.set(data, forKey: PersistKey.codex)
        }
        defaults.set(Date.now, forKey: PersistKey.updated)
    }

    private var timer: Timer?

    /// The in-flight refresh, so concurrent callers coalesce instead of being
    /// dropped. `refreshToken` guards the teardown against interleaved tasks.
    private var refreshTask: Task<Void, Never>?
    private var refreshToken = 0

    /// How old the data may be before opening the menu re-fetches. Keeps a quick
    /// open right after a timer tick from spawning a redundant Codex subprocess.
    private let staleAfter: TimeInterval = 20

    /// True when the data is missing or old enough to justify a refetch.
    var isStale: Bool {
        guard let lastUpdated else { return true }
        return Date.now.timeIntervalSince(lastUpdated) >= staleAfter
    }

    // MARK: - Menu-bar selection

    /// Providers that currently have usage data and can be pinned.
    var selectableProviders: [String] {
        providers.filter { $0.hasWindows }.map { $0.name }
    }

    func setPinned(_ provider: String?) { pinnedProvider = provider }

    /// Label for the "pick whichever provider is closest to its limit" option.
    static let autoLabel = "Auto (highest)"

    var pinnedDisplayLabel: String { pinnedProvider ?? Self.autoLabel }

    /// The provider shown in the menu bar: the pinned one, else the highest 5h.
    private var menuBarProvider: ProviderUsage? {
        if let name = pinnedProvider,
            let match = providers.first(where: { $0.name == name && $0.hasWindows })
        {
            return match
        }
        return
            providers
            .filter { $0.hasWindows }
            .max { ($0.fiveHour?.usedPercent ?? -1) < ($1.fiveHour?.usedPercent ?? -1) }
    }

    /// A gauge whose needle reflects the menu-bar provider's 5hr usage.
    /// Stays monochrome (uncolored) — only the dropdown bars use color.
    var menuBarIcon: String {
        guard let pct = menuBarProvider?.fiveHour?.usedPercent else {
            return "gauge.with.dots.needle.bottom.50percent"
        }
        switch pct {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<40: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<80: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    /// Full: "Claude  5h 7% · Wk 31%". Compact: "Claude  5h 7%".
    /// With a single provider the name is dropped (e.g. "5h 7% · Wk 31%").
    var menuBarTitle: String {
        guard let p = menuBarProvider else { return "—" }
        var parts: [String] = []
        if let f = p.fiveHour { parts.append("5h \(Format.percent(f.usedPercent))") }
        if !compactMenuBar, let w = p.weekly { parts.append("Wk \(Format.percent(w.usedPercent))") }
        let body = parts.joined(separator: " · ")
        if body.isEmpty { return p.name }
        // Only label the provider when more than one is available.
        return selectableProviders.count > 1 ? "\(p.name)  \(body)" : body
    }

    func startAutoRefresh(interval: TimeInterval = 60) {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// `force` ignores the Claude throttle (used by the manual refresh button).
    /// Concurrent calls coalesce onto the in-flight refresh rather than being
    /// dropped; a forced call awaits any running pass, then runs its own.
    func refresh(force: Bool = false) async {
        if let task = refreshTask {
            await task.value
            if !force { return }  // non-forced callers reuse the just-finished pass
        }
        refreshToken &+= 1
        let myToken = refreshToken
        let task = Task { await self.performRefresh(force: force) }
        refreshTask = task
        await task.value
        if refreshToken == myToken { refreshTask = nil }
    }

    private func performRefresh(force: Bool) async {
        isLoading = true
        defer { isLoading = false }

        // Codex is cheap/local — always refresh it.
        async let codexResult = CodexClient.fetch()

        // Probe Claude only when due. After a success that's a calm 5-min cadence;
        // after consecutive failures it's an exponential back-off so we stop
        // hammering an endpoint that's telling us it's throttled.
        let claudeInterval: TimeInterval =
            claudeFailureStreak == 0
            ? claudeSuccessInterval
            : min(claudeBackoffBase * pow(2, Double(claudeFailureStreak - 1)), claudeBackoffMax)
        let claudeDue: Bool =
            if force {
                true
            } else if let last = claudeLastAttempt {
                Date.now.timeIntervalSince(last) >= claudeInterval
            } else {
                true  // never attempted yet
            }
        async let claudeResult: ProviderUsage? = claudeDue ? ClaudeClient.fetch() : nil
        if claudeDue { claudeLastAttempt = .now }

        let codex = resolve(await codexResult, lastGood: &lastGoodCodex)
        let claude: ProviderUsage
        if let fresh = await claudeResult {
            claude = resolve(fresh, lastGood: &lastGoodClaude)
            claudeFailureStreak = fresh.allWindows.isEmpty ? claudeFailureStreak + 1 : 0
        } else {
            claude = lastGoodClaude ?? .failed("Claude", "Updating…", retryable: true)
        }

        providers = [claude, codex]
        lastUpdated = .now
    }

    /// Prefer fresh windows; otherwise fall back to the last good snapshot and
    /// annotate it as stale rather than blanking the row.
    private func resolve(_ fresh: ProviderUsage, lastGood: inout ProviderUsage?) -> ProviderUsage {
        if !fresh.allWindows.isEmpty {
            lastGood = fresh
            return fresh
        }
        guard let prev = lastGood else { return fresh }  // no history → surface the error
        let note = fresh.retryable ? "throttled — showing last value" : (fresh.error ?? "stale")
        return ProviderUsage(
            name: prev.name,
            pools: prev.pools,
            error: note,
            plan: prev.plan ?? fresh.plan,
            retryable: fresh.retryable
        )
    }
}
