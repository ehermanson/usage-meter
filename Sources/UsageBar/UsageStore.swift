import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var providers: [ProviderUsage] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

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

    func refresh() async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        async let claude = ClaudeClient.fetch()
        async let codex = CodexClient.fetch()
        providers = await [claude, codex]
        lastUpdated = Date()
    }
}
