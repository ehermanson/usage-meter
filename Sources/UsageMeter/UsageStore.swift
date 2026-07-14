import Observation
import SwiftUI

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()

    var providers: [ProviderUsage] = []
    var isLoading = false
    var lastUpdated: Date?

    /// The sections actually shown: providers whose CLI/credentials were found on
    /// this machine. A tool the user doesn't have installed is hidden entirely —
    /// using the app with a single provider is a fully supported state.
    var visibleProviders: [ProviderUsage] { providers.filter { $0.detected } }

    /// Which provider is pinned to the menu-bar title; nil = Auto (highest 5h).
    var pinnedProvider: String? = UserDefaults.standard.string(forKey: "pinnedProvider") {
        didSet { UserDefaults.standard.set(pinnedProvider, forKey: "pinnedProvider") }
    }

    /// Compact menu-bar title: show only the 5hr window, skip weekly.
    var compactMenuBar: Bool = UserDefaults.standard.bool(forKey: "compactMenuBar") {
        didSet { UserDefaults.standard.set(compactMenuBar, forKey: "compactMenuBar") }
    }

    /// Show each window as percent *remaining* (e.g. "89%") instead of percent
    /// *used* ("11%). Flips the number, the bar fill, and the menu-bar title
    /// together; the danger color still keys off actual usage.
    var showRemaining: Bool = UserDefaults.standard.bool(forKey: "showRemaining") {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }

    /// The providers polled each pass, in display order. Add one here to surface a
    /// new source — the fetch loop, throttling, last-good caching, and section
    /// styling are all keyed off this list, so nothing else needs to change.
    private let registry: [UsageProvider] = [ClaudeProvider(), CodexProvider(), GeminiProvider()]

    /// Per-provider bookkeeping, keyed by name so it scales with the registry
    /// instead of a field apiece. `failureStreak` drives the throttle back-off;
    /// `lastGood` is the last snapshot with windows, shown when a fetch fails.
    private struct ProviderState {
        var lastAttempt: Date?
        var failureStreak = 0
        var lastGood: ProviderUsage?
        /// The last value actually shown for this provider (any state, including
        /// `.notDetected`). Reused for a provider that isn't due this pass so an
        /// undetected/hidden provider doesn't flash a placeholder row.
        var lastResolved: ProviderUsage?
    }
    private var states: [String: ProviderState] = [:]

    private enum PersistKey {
        static func lastGood(_ name: String) -> String { "lastGood.\(name).v1" }
        static let updated = "lastGoodUpdated.v1"
    }

    private init() { loadLastGood() }

    /// Seed `lastGood` and the visible rows from disk so the menu has data the
    /// instant it opens, before the first (possibly throttled) probe returns.
    private func loadLastGood() {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var seeded: [ProviderUsage] = []
        for provider in registry {
            guard let data = defaults.data(forKey: PersistKey.lastGood(provider.name)),
                let usage = try? decoder.decode(ProviderUsage.self, from: data)
            else { continue }
            states[provider.name, default: .init()].lastGood = usage
            seeded.append(usage)
        }
        if !seeded.isEmpty {
            providers = seeded
            lastUpdated = defaults.object(forKey: PersistKey.updated) as? Date
        }
    }

    private func persistLastGood() {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        for provider in registry {
            let key = PersistKey.lastGood(provider.name)
            if let usage = states[provider.name]?.lastGood,
                let data = try? encoder.encode(usage)
            {
                defaults.set(data, forKey: key)
            } else {
                // `lastGood` was dropped by a hard failure (signed out, plan
                // limits no longer apply). Remove the persisted copy too —
                // otherwise the next launch re-seeds the stale numbers into the
                // menu bar, and the first refresh wipes them again, an endless
                // show-then-clear loop.
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(Date.now, forKey: PersistKey.updated)
    }

    /// Display attributes for a provider's section, looked up by name so views
    /// don't hardcode per-provider styling.
    func style(for name: String) -> (accent: Color, logoResource: String?) {
        guard let provider = registry.first(where: { $0.name == name }) else {
            return (.accentColor, nil)
        }
        return (provider.accent, provider.logoResource)
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

    /// Full: "Claude  5h 7% · Wk 31%". Compact: "Claude  5h 7%". A provider with
    /// no 5h/weekly split shows its own window label (e.g. "Gemini  Daily 12%").
    /// With a single provider the name is dropped (e.g. "5h 7% · Wk 31%").
    var menuBarTitle: String {
        guard let p = menuBarProvider else { return "—" }
        var parts: [String] = []
        if let f = p.fiveHour {
            parts.append("\(Self.shortLabel(f.label)) \(Format.percent(displayPercent(f)))")
        }
        if !compactMenuBar, let w = p.weekly, w.id != p.fiveHour?.id {
            parts.append("\(Self.shortLabel(w.label)) \(Format.percent(displayPercent(w)))")
        }
        let body = parts.joined(separator: " · ")
        if body.isEmpty { return p.name }
        // Only label the provider when more than one is available.
        return selectableProviders.count > 1 ? "\(p.name)  \(body)" : body
    }

    /// Whether the "Compact" toggle does anything worth offering. It only drops
    /// the weekly window from the menu-bar title, so it's meaningless for a
    /// provider with no distinct 5h/weekly split — e.g. a fixed-budget Enterprise
    /// plan that reports only a single "Usage" window. Hidden unless some shown
    /// provider actually has a weekly window to collapse.
    var compactMenuBarApplies: Bool {
        providers.contains { p in
            p.hasWindows && p.weekly != nil && p.weekly?.id != p.fiveHour?.id
        }
    }

    /// The percentage to show for a window, honoring the used/remaining setting.
    func displayPercent(_ window: UsageWindow) -> Double {
        showRemaining ? window.remainingPercent : window.usedPercent
    }

    /// Compact window labels for the menu bar: the verbose pool labels collapse to
    /// "5h"/"Wk"; anything else (e.g. "Daily") is shown as-is.
    private static func shortLabel(_ label: String) -> String {
        if label.localizedCaseInsensitiveContains("5h") { return "5h" }
        if label.localizedCaseInsensitiveContains("week") || label.contains("7d") { return "Wk" }
        return label
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

        // Kick off every due provider's fetch concurrently. A provider is due when
        // forced, never attempted, or its throttle interval has elapsed since the
        // last attempt (the interval widens with each consecutive failure).
        var tasks: [String: Task<ProviderUsage, Never>] = [:]
        for provider in registry {
            let state = states[provider.name] ?? .init()
            let due: Bool
            if force || state.lastAttempt == nil {
                due = true
            } else {
                let interval = provider.throttle.interval(failureStreak: state.failureStreak)
                due = Date.now.timeIntervalSince(state.lastAttempt!) >= interval
            }
            if due {
                states[provider.name, default: .init()].lastAttempt = .now
                tasks[provider.name] = Task { await provider.fetch() }
            }
        }

        // Resolve in registry order so the section order stays stable. Providers
        // skipped this pass reuse their last good snapshot.
        var resolved: [ProviderUsage] = []
        for provider in registry {
            let name = provider.name
            guard let task = tasks[name] else {
                // Not due this pass — reuse whatever was last shown (which may be
                // `.notDetected`, i.e. hidden) rather than a fabricated placeholder.
                resolved.append(states[name]?.lastResolved ?? .notDetected(name))
                continue
            }
            let fresh = await task.value
            states[name, default: .init()].failureStreak =
                fresh.allWindows.isEmpty ? (states[name]?.failureStreak ?? 0) + 1 : 0
            let resolvedValue = resolve(fresh, name: name)
            states[name, default: .init()].lastResolved = resolvedValue
            resolved.append(resolvedValue)
        }

        providers = resolved
        lastUpdated = .now
        persistLastGood()
    }

    /// Prefer fresh windows. For a *retryable* failure (e.g. a throttled endpoint)
    /// keep showing the last good snapshot rather than blanking the row. A
    /// *non-retryable* failure (signed out, account/config mismatch) means the old
    /// values are no longer trustworthy, so drop them and surface the error.
    private func resolve(_ fresh: ProviderUsage, name: String) -> ProviderUsage {
        if !fresh.allWindows.isEmpty {
            states[name, default: .init()].lastGood = fresh
            return fresh
        }
        guard fresh.retryable, let prev = states[name]?.lastGood else {
            states[name]?.lastGood = nil  // no stale data for hard failures
            return fresh
        }
        return ProviderUsage(
            name: prev.name,
            pools: prev.pools,
            error: "throttled — showing last value",
            plan: prev.plan ?? fresh.plan,
            retryable: true
        )
    }
}
