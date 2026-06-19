import SwiftUI

/// How often a provider may be probed. A cheap/local source refreshes every pass
/// (the default, `.eager`). An expensive or itself-rate-limited endpoint settles
/// to `successInterval` after a good fetch and backs off exponentially from
/// `backoffBase` (capped at `backoffMax`) after consecutive failures, so we stop
/// hammering an endpoint that's telling us it's throttled.
struct ThrottlePolicy: Sendable {
    var successInterval: TimeInterval = 0
    var backoffBase: TimeInterval = 0
    var backoffMax: TimeInterval = 0

    /// No throttling — refresh on every pass.
    static let eager = ThrottlePolicy()

    /// Seconds that must elapse since the last attempt before probing again,
    /// given how many consecutive failures preceded now.
    func interval(failureStreak: Int) -> TimeInterval {
        guard failureStreak > 0, backoffBase > 0 else { return successInterval }
        return min(backoffBase * pow(2, Double(failureStreak - 1)), backoffMax)
    }
}

/// A pluggable usage source. Each provider encapsulates its own fetch mechanism
/// (Node SDK helper, JSON-RPC subprocess, REST, …) and reports into the shared
/// `ProviderUsage` schema, so the store and UI stay provider-agnostic.
///
/// To add a provider: implement `fetch()` returning a `ProviderUsage`, then add
/// one instance to `UsageStore.registry`. Throttling, last-good caching, section
/// ordering, accent, and logo all flow from the values declared here.
protocol UsageProvider: Sendable {
    /// Display name; must match the `name` on the `ProviderUsage` it returns.
    var name: String { get }
    /// Brand-ish accent so each provider reads as a distinct section.
    var accent: Color { get }
    /// Bundled brand logo resource (PNG) name, or nil to fall back to a dot.
    var logoResource: String? { get }
    /// How often this source may be probed.
    var throttle: ThrottlePolicy { get }
    func fetch() async -> ProviderUsage
}

extension UsageProvider {
    var logoResource: String? { nil }
    var throttle: ThrottlePolicy { .eager }
}

/// Claude — driven through the Claude Agent SDK's get_usage control request via a
/// small Node helper. Its usage endpoint is itself rate-limited, so probe it
/// sparingly: settle to 5 min after a success, back off 3→6→12→15 min on failures.
struct ClaudeProvider: UsageProvider {
    let name = "Claude"
    let accent = Color.orange
    let logoResource: String? = "claude-logo"
    let throttle = ThrottlePolicy(successInterval: 300, backoffBase: 180, backoffMax: 900)
    func fetch() async -> ProviderUsage { await ClaudeClient.fetch() }
}

/// Codex — driven by a short-lived `codex app-server` JSON-RPC subprocess.
/// Cheap and local, so it refreshes on every pass.
struct CodexProvider: UsageProvider {
    let name = "Codex"
    let accent = Color.teal
    let logoResource: String? = "codex-logo"
    func fetch() async -> ProviderUsage { await CodexClient.fetch() }
}

/// Gemini — fetched from the Code Assist backend using the Antigravity CLI's
/// stored OAuth credentials. Hits Google over HTTPS (and may refresh a token),
/// so probe at a calm cadence with a back-off on failures.
struct GeminiProvider: UsageProvider {
    let name = "Gemini"
    let accent = Color.blue
    let logoResource: String? = "gemini-logo"
    let throttle = ThrottlePolicy(successInterval: 180, backoffBase: 120, backoffMax: 600)
    func fetch() async -> ProviderUsage { await GeminiClient.fetch() }
}
