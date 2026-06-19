import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var providers: [ProviderUsage] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    /// Claude's usage endpoint is itself rate-limited, so probe it sparingly.
    private let claudeMinInterval: TimeInterval = 300
    private var claudeLastAttempt: Date?

    /// Last successful snapshots, shown when a refresh fails/throttles.
    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?

    private var timer: Timer?

    /// Highest 5h utilization across providers — drives the menu-bar title.
    var peakFiveHour: Double {
        providers.compactMap { $0.fiveHour?.usedPercent }.max() ?? 0
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
