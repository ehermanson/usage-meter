import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var providers: [ProviderUsage] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    /// Which provider is pinned to the menu-bar title; nil = Auto (highest 5h).
    @Published var pinnedProvider: String? = UserDefaults.standard.string(forKey: "pinnedProvider") {
        didSet { UserDefaults.standard.set(pinnedProvider, forKey: "pinnedProvider") }
    }

    /// Compact menu-bar title: show only the 5hr window, skip weekly.
    @Published var compactMenuBar: Bool = UserDefaults.standard.bool(forKey: "compactMenuBar") {
        didSet { UserDefaults.standard.set(compactMenuBar, forKey: "compactMenuBar") }
    }

    /// Claude's usage endpoint is itself rate-limited, so probe it sparingly.
    private let claudeMinInterval: TimeInterval = 300
    private var claudeLastAttempt: Date?

    /// Last successful snapshots, shown when a refresh fails/throttles.
    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?

    private var timer: Timer?

    // MARK: - Menu-bar selection

    /// Providers that currently have usage data and can be pinned.
    var selectableProviders: [String] {
        providers.filter { $0.hasWindows }.map { $0.name }
    }

    func setPinned(_ provider: String?) { pinnedProvider = provider }

    var pinnedDisplayLabel: String { pinnedProvider ?? "Auto (peak)" }

    /// The provider shown in the menu bar: the pinned one, else the highest 5h.
    private var menuBarProvider: ProviderUsage? {
        if let name = pinnedProvider,
           let match = providers.first(where: { $0.name == name && $0.hasWindows }) {
            return match
        }
        return providers
            .filter { $0.hasWindows }
            .max { ($0.fiveHour?.usedPercent ?? -1) < ($1.fiveHour?.usedPercent ?? -1) }
    }

    /// Full: "Claude  5hr: 7% | Weekly 31%". Compact: "Claude  5hr: 7%".
    /// With a single provider the name is dropped (e.g. "5hr: 7% | Weekly 31%").
    var menuBarTitle: String {
        guard let p = menuBarProvider else { return "—" }
        var parts: [String] = []
        if let f = p.fiveHour { parts.append("5hr: \(Format.percent(f.usedPercent))") }
        if !compactMenuBar, let w = p.weekly { parts.append("Weekly \(Format.percent(w.usedPercent))") }
        let body = parts.joined(separator: " | ")
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
    func refresh(force: Bool = false) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        // Codex is cheap/local — always refresh it.
        async let codexResult = CodexClient.fetch()

        // Claude is throttled to protect its rate-limited usage endpoint.
        let claudeDue = force
            || claudeLastAttempt == nil
            || Date().timeIntervalSince(claudeLastAttempt!) >= claudeMinInterval
        async let claudeResult: ProviderUsage? = claudeDue ? ClaudeClient.fetch() : nil
        if claudeDue { claudeLastAttempt = Date() }

        let codex = resolve(await codexResult, lastGood: &lastGoodCodex)
        let claude: ProviderUsage
        if let fresh = await claudeResult {
            claude = resolve(fresh, lastGood: &lastGoodClaude)
        } else {
            claude = lastGoodClaude ?? .failed("Claude", "Updating…", retryable: true)
        }

        providers = [claude, codex]
        lastUpdated = Date()
    }

    /// Prefer fresh windows; otherwise fall back to the last good snapshot and
    /// annotate it as stale rather than blanking the row.
    private func resolve(_ fresh: ProviderUsage, lastGood: inout ProviderUsage?) -> ProviderUsage {
        if !fresh.allWindows.isEmpty {
            lastGood = fresh
            return fresh
        }
        guard let prev = lastGood else { return fresh } // no history → surface the error
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
