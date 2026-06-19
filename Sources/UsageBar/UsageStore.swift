import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var providers: [ProviderUsage] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    /// Which window is pinned to the menu-bar title; nil = Auto (highest 5h).
    @Published var pinnedKey: String? = UserDefaults.standard.string(forKey: "pinnedWindowKey") {
        didSet { UserDefaults.standard.set(pinnedKey, forKey: "pinnedWindowKey") }
    }

    /// Claude's usage endpoint is itself rate-limited, so probe it sparingly.
    private let claudeMinInterval: TimeInterval = 300
    private var claudeLastAttempt: Date?

    /// Last successful snapshots, shown when a refresh fails/throttles.
    private var lastGoodClaude: ProviderUsage?
    private var lastGoodCodex: ProviderUsage?

    private var timer: Timer?

    // MARK: - Menu-bar selection

    struct SelectableWindow: Identifiable {
        let key: String
        let display: String      // "Claude · Weekly · Sonnet"
        let provider: String
        let percent: Double
        var id: String { key }
    }

    static func windowKey(provider: String, poolTitle: String?, windowLabel: String) -> String {
        "\(provider)\u{1}\(poolTitle ?? "")\u{1}\(windowLabel)"
    }

    /// Every window the user can pin to the menu bar.
    var selectableWindows: [SelectableWindow] {
        var out: [SelectableWindow] = []
        for p in providers {
            for pool in p.pools {
                for w in pool.windows {
                    let display = [p.name, pool.title, w.label]
                        .compactMap { $0 }.joined(separator: " · ")
                    out.append(.init(
                        key: Self.windowKey(provider: p.name, poolTitle: pool.title, windowLabel: w.label),
                        display: display, provider: p.name, percent: w.usedPercent))
                }
            }
        }
        return out
    }

    func setPinned(_ key: String?) { pinnedKey = key }

    var pinnedDisplayLabel: String {
        if let key = pinnedKey, let sel = selectableWindows.first(where: { $0.key == key }) {
            return sel.display
        }
        return "Auto (peak)"
    }

    /// (tag, percent) for the menu-bar title; honors the pin, else highest 5h.
    var menuBar: (tag: String, percent: Double)? {
        if let key = pinnedKey, let sel = selectableWindows.first(where: { $0.key == key }) {
            return (Self.shortCode(sel.provider), sel.percent)
        }
        var best: (String, Double)?
        for p in providers {
            guard let f = p.fiveHour else { continue }
            if best == nil || f.usedPercent > best!.1 {
                best = (Self.shortCode(p.name), f.usedPercent)
            }
        }
        return best
    }

    var menuBarTitle: String {
        guard let mb = menuBar else { return "—" }
        return "\(mb.tag) \(Format.percent(mb.percent))"
    }

    static func shortCode(_ name: String) -> String {
        switch name {
        case "Claude": return "Cl"
        case "Codex": return "Cx"
        default: return String(name.prefix(2))
        }
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
