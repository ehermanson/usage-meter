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

    /// How much the menu-bar item spells out, from both windows down to a bare
    /// ring — and whether it tracks one provider or all of them.
    var menuBarStyle: MenuBarStyle = UsageStore.loadMenuBarStyle() {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }

    /// Carries over the boolean "compact" preference this replaced: the two
    /// states it switched between are now two of four, so an existing `true`
    /// lands on `.compact` and anything else on `.full`.
    private static func loadMenuBarStyle() -> MenuBarStyle {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "menuBarStyle"),
            let style = MenuBarStyle(rawValue: raw)
        {
            return style
        }
        return defaults.bool(forKey: "compactMenuBar") ? .compact : .full
    }

    /// Show each window as percent *remaining* (e.g. "89%") instead of percent
    /// *used* ("11%). Flips the number, the bar fill, and the menu-bar title
    /// together; the danger color still keys off actual usage.
    var showRemaining: Bool = UserDefaults.standard.bool(forKey: "showRemaining") {
        didSet { UserDefaults.standard.set(showRemaining, forKey: "showRemaining") }
    }

    /// Explicit CLAUDE_CONFIG_DIR for the Claude fetch; nil = auto-detect (the
    /// helper mirrors the terminal: explicit env, login-shell export, then
    /// ~/.claude when file credentials live there). The escape hatch for setups
    /// the heuristic can't see — e.g. a config dir only ever named inside a
    /// shell alias. Changing it refetches immediately so the effect is visible.
    var claudeConfigDir: String? = UserDefaults.standard.string(forKey: "claudeConfigDir") {
        didSet {
            UserDefaults.standard.set(claudeConfigDir, forKey: "claudeConfigDir")
            Task { await refresh(force: true) }
        }
    }

    /// Short label for the config-dir picker: "Auto" or the folder with the
    /// home directory abbreviated ("~/.claude").
    var claudeConfigDirLabel: String {
        guard let dir = claudeConfigDir else { return "Auto" }
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
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

    /// What the menu-bar item draws: the provider's mark inside a ring showing
    /// its 5hr usage, then the windows as styled text runs.
    ///
    /// This is the visual twin of `menuBarTitle` below, which stays the flat
    /// string — it's what VoiceOver reads and what the tests pin. The two are
    /// built from the same `displayPercent`/`shortLabel` helpers and say the
    /// same thing; they differ only in that the mark lets this one drop the
    /// provider's name, which the string still has to spell out.
    var menuBarDisplay: MenuBarDisplay {
        // One ring per provider, no text — which provider is which is carried
        // entirely by the marks, and the numbers move to the tooltip.
        if menuBarStyle == .allProviders {
            let tracked = providers.filter { $0.hasWindows }
            guard !tracked.isEmpty else { return Self.placeholderDisplay }
            return MenuBarDisplay(glyphs: tracked.map(glyph(for:)), segments: [])
        }

        guard let p = menuBarProvider else { return Self.placeholderDisplay }
        let logo = style(for: p.name).logoResource

        var values: [MenuBarSegment] = []
        if menuBarStyle != .ringOnly {
            if let f = p.fiveHour {
                values.append(MenuBarSegment(text: Self.shortLabel(f.label), style: .label))
                values.append(
                    MenuBarSegment(text: Format.percent(displayPercent(f)), style: .primary))
            }
            if menuBarStyle == .full, let w = p.weekly, w.id != p.fiveHour?.id {
                values.append(MenuBarSegment(text: Self.shortLabel(w.label), style: .label))
                values.append(
                    MenuBarSegment(text: Format.percent(displayPercent(w)), style: .secondary))
            }
        }

        // A fixed-budget plan's lone "Usage" window isn't self-describing the
        // way "5h 7% · Wk 31%" is, so say which way its number runs.
        let isFixedBudget = values.count == 2 && p.fiveHour?.label == "Usage"
        if isFixedBudget && showRemaining {
            values.append(MenuBarSegment(text: "left", style: .label))
        }

        var segments: [MenuBarSegment] = []
        // The mark already says which provider this is, so the name is only
        // spelled out when there's no logo to carry it — and never when there's
        // no text at all to attach it to.
        if logo == nil, !values.isEmpty, selectableProviders.count > 1 || isFixedBudget {
            segments.append(MenuBarSegment(text: p.name, style: .label))
        }
        segments.append(contentsOf: values)

        return MenuBarDisplay(glyphs: [glyph(for: p)], segments: segments)
    }

    /// Nothing to show yet: an empty ring and a dash.
    private static let placeholderDisplay = MenuBarDisplay(
        glyphs: [MenuBarGlyph(id: "—", fraction: 0, severity: 0, logoResource: nil)],
        segments: [MenuBarSegment(text: "—", style: .label)])

    /// A provider's ring. The arc tracks whatever the numbers say — filling with
    /// usage, or draining as headroom shrinks — while its color always keys off
    /// usage, so a nearly-drained ring still reads red. Same split the dropdown's
    /// bars use (see `WindowBar.barFraction` / `barColor`).
    private func glyph(for p: ProviderUsage) -> MenuBarGlyph {
        let used = (p.fiveHour?.usedPercent ?? 0) / 100
        return MenuBarGlyph(
            id: p.name,
            fraction: showRemaining ? 1 - used : used,
            severity: used,
            logoResource: style(for: p.name).logoResource)
    }

    /// What the item means, spelled out in full for the tooltip and VoiceOver.
    /// Independent of `menuBarStyle`: the terser the item is drawn, the more
    /// this is carrying, and in `.ringOnly` it's the only place the numbers
    /// appear at all.
    var menuBarTooltip: String {
        let described: [String]
        if menuBarStyle == .allProviders {
            described = providers.filter { $0.hasWindows }.map(describe(_:))
        } else {
            described = menuBarProvider.map { [describe($0)] } ?? []
        }
        return described.isEmpty ? "No usage to show" : described.joined(separator: "\n")
    }

    private func describe(_ p: ProviderUsage) -> String {
        var parts: [String] = []
        if let f = p.fiveHour {
            parts.append("\(Self.shortLabel(f.label)) \(Format.percent(displayPercent(f)))")
        }
        if let w = p.weekly, w.id != p.fiveHour?.id {
            parts.append("\(Self.shortLabel(w.label)) \(Format.percent(displayPercent(w)))")
        }
        guard !parts.isEmpty else { return p.name }
        return "\(p.name) — \(parts.joined(separator: " · ")) \(showRemaining ? "left" : "used")"
    }

    /// "Claude  5h 7% · Wk 31%". A provider with no 5h/weekly split shows its own
    /// window label (e.g. "Gemini  Daily 12%"). With a single provider the name
    /// is dropped (e.g. "5h 7% · Wk 31%") — except for a fixed-budget plan's
    /// generic "Usage" window, which always carries the name ("Claude Usage 6%",
    /// or "Claude Usage 94% left").
    ///
    /// Always the full description, whatever `menuBarStyle` draws: this is the
    /// accessibility label, so it should say everything the item stands for even
    /// when the item itself is only a ring.
    var menuBarTitle: String {
        guard let p = menuBarProvider else { return "—" }
        var parts: [String] = []
        if let f = p.fiveHour {
            parts.append("\(Self.shortLabel(f.label)) \(Format.percent(displayPercent(f)))")
        }
        if let w = p.weekly, w.id != p.fiveHour?.id {
            parts.append("\(Self.shortLabel(w.label)) \(Format.percent(displayPercent(w)))")
        }
        let body = parts.joined(separator: " · ")
        if body.isEmpty { return p.name }
        // A fixed-budget plan's lone "Usage" window isn't self-describing the
        // way "5h 7% · Wk 31%" is — always name the provider for it, and say
        // which way the number runs when it counts down instead of up.
        if parts.count == 1, p.fiveHour?.label == "Usage" {
            return "\(p.name) \(body)\(showRemaining ? " left" : "")"
        }
        // Otherwise only label the provider when more than one is available.
        return selectableProviders.count > 1 ? "\(p.name)  \(body)" : body
    }

    /// The styles worth offering on this machine. Two of the four only mean
    /// something given the right data, and an option that visibly does nothing
    /// is worse than one that isn't there:
    ///
    /// - `.compact` drops the weekly window, so it's indistinguishable from
    ///   `.full` for a provider with no distinct 5h/weekly split — e.g. a
    ///   fixed-budget Enterprise plan reporting a single "Usage" window.
    /// - `.allProviders` needs more than one provider to be worth the name.
    ///
    /// Whatever is currently selected always stays in the list, even once the
    /// data that justified it has gone: a provider signing out shouldn't leave
    /// the picker showing "Ring per provider" with nothing ticked beneath it.
    var availableMenuBarStyles: [MenuBarStyle] {
        MenuBarStyle.allCases.filter { style in
            if style == menuBarStyle { return true }
            switch style {
            case .full, .ringOnly: return true
            case .compact: return providers.contains { $0.hasWindows && $0.hasDistinctWeekly }
            case .allProviders: return selectableProviders.count > 1
            }
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

    /// Runs one provider's fetch, giving up after its `fetchTimeout`.
    ///
    /// Deliberately races two *unstructured* tasks rather than using a task
    /// group: a group awaits its children before returning, so a child wedged in
    /// a synchronous system call would keep the group — and this pass — waiting
    /// no matter how promptly the timeout fired. Cancellation is no help either,
    /// since a blocked `SecItemCopyMatching` never reaches a cancellation point.
    /// Abandoning the task is the only thing that actually works; it occupies a
    /// thread until the call returns on its own, which is a far better trade
    /// than freezing every provider's data and the timestamp behind it.
    static func fetch(_ provider: UsageProvider) async -> ProviderUsage {
        let winner = FirstResult()
        return await withCheckedContinuation { continuation in
            Task {
                let usage = await provider.fetch()
                if await winner.claim() { continuation.resume(returning: usage) }
            }
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(provider.fetchTimeout * 1_000_000_000))
                if await winner.claim() {
                    // Retryable, so the last good snapshot keeps showing instead
                    // of the row blanking out over a transient stall.
                    continuation.resume(
                        returning: .failed(provider.name, "not responding", retryable: true))
                }
            }
        }
    }

    /// Lets exactly one of two racing tasks resume the continuation.
    private actor FirstResult {
        private var claimed = false
        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }
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
                tasks[provider.name] = Task { await Self.fetch(provider) }
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
        // Carry the actual reason through rather than always saying "throttled":
        // a fetch that timed out is a different thing to explain than an
        // endpoint that turned us away, and the row is the only place it shows.
        return ProviderUsage(
            name: prev.name,
            pools: prev.pools,
            error: "\(fresh.error ?? "unavailable") — showing last value",
            plan: prev.plan ?? fresh.plan,
            retryable: true
        )
    }
}
