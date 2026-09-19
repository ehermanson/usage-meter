import Foundation

/// One rate-limit window for a provider (e.g. the 5-hour rolling window).
/// `id` is derived from the (unique-per-pool) label so identity survives refetches
/// — a fresh fetch with the same window keeps its view, letting the bar animate.
struct UsageWindow: Identifiable, Equatable, Codable {
    var id: String { label }
    let label: String  // "5h", "Weekly", "7d · Sonnet"
    let usedPercent: Double  // 0...100
    let resetAt: Date?
    /// Optional caption shown where the reset countdown would go, for windows
    /// without a reset — e.g. a dollar-budget window's "$237 / $300".
    var detail: String? = nil

    var clampedFraction: Double { max(0, min(1, usedPercent / 100)) }

    /// Headroom left in the window, 0...100 — the complement of `usedPercent`.
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
}

/// A named group of windows. `title == nil` is the provider's default pool;
/// named pools (e.g. a per-model limit) carry a subheader.
struct UsagePool: Identifiable, Equatable, Codable {
    var id: String { title ?? "" }  // pool titles are unique within a provider
    let title: String?
    var windows: [UsageWindow]
}

/// A provider that can't report usage because something on *this machine* needs
/// setting up — a missing CLI/runtime, or simply not being signed in. This is an
/// expected, calm state (not an error), so the UI presents it gently and points
/// the user at the fix instead of showing an alarming red message.
struct SetupHint: Equatable, Codable {
    let message: String  // "Sign in to Claude Code to track usage"
    var url: String? = nil  // optional "Set up ↗" link
}

/// Free rate-limit resets a provider has granted the account (Codex hands
/// these out periodically). Redeeming one clears the current windows outright,
/// so the count is worth showing next to the bars it can wipe.
struct ResetCredits: Equatable, Codable {
    let available: Int
    /// When the soonest-expiring credit lapses, if the provider says.
    var earliestExpiry: Date? = nil
}

/// Aggregated usage for a single provider.
struct ProviderUsage: Identifiable, Equatable, Codable {
    var id: String { name }  // one section per provider
    let name: String  // "Claude", "Codex"
    var pools: [UsagePool]
    var error: String? = nil
    var plan: String? = nil  // "Max", "Pro", "Pro Lite", …
    /// A soft, retryable failure (e.g. usage endpoint momentarily throttled) —
    /// the store keeps showing the last good values when this is set.
    var retryable: Bool = false
    /// Set when the provider needs user setup (tool not installed / not signed
    /// in). Rendered as a calm hint rather than an error when there are no windows.
    var setup: SetupHint? = nil
    /// False when the provider's CLI/credentials weren't found on this machine at
    /// all — the user doesn't use this tool, so its section is hidden entirely
    /// (no nudge to install something they didn't ask for). Not persisted: only
    /// successful, windowed snapshots are cached, and those are always detected.
    var detected: Bool = true
    /// When these windows were actually fetched. Stamped by the store as it
    /// caches a windowed snapshot, and persisted with it, so a value carried
    /// forward past a failed refresh can say how old it is — and be dropped
    /// once it's too old to describe anything current.
    var capturedAt: Date? = nil
    /// Free resets the account can redeem, when the provider offers any.
    var resetCredits: ResetCredits? = nil

    private enum CodingKeys: String, CodingKey {
        case name, pools, error, plan, retryable, setup, capturedAt, resetCredits
    }

    var allWindows: [UsageWindow] { pools.flatMap { $0.windows } }

    /// The primary (5h) window, used for the compact menu-bar title.
    var fiveHour: UsageWindow? {
        allWindows.first { $0.label.localizedCaseInsensitiveContains("5h") }
            ?? allWindows.first
    }

    /// The primary weekly window (the broad "all" pool, not a model-scoped one).
    var weekly: UsageWindow? {
        allWindows.first {
            $0.label.localizedCaseInsensitiveContains("week")
                || $0.label.localizedCaseInsensitiveContains("7d")
        }
    }

    var hasWindows: Bool { !allWindows.isEmpty }

    /// True when the weekly window is a separate thing from the 5hr one, so
    /// showing both says more than showing one.
    var hasDistinctWeekly: Bool { weekly != nil && weekly?.id != fiveHour?.id }

    static func ok(
        _ name: String, pools: [UsagePool], plan: String? = nil,
        resetCredits: ResetCredits? = nil
    ) -> ProviderUsage {
        ProviderUsage(name: name, pools: pools, error: nil, plan: plan, resetCredits: resetCredits)
    }

    static func failed(
        _ name: String, _ message: String,
        retryable: Bool = false, plan: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(name: name, pools: [], error: message, plan: plan, retryable: retryable)
    }

    /// The provider needs setup on this machine (tool missing / not signed in).
    /// Not retryable in the throttle sense — there's no stale value worth keeping,
    /// so the calm hint is shown until the user acts and a later probe succeeds.
    static func needsSetup(
        _ name: String, _ message: String, url: String? = nil, plan: String? = nil
    ) -> ProviderUsage {
        ProviderUsage(
            name: name, pools: [], error: nil, plan: plan, retryable: false,
            setup: SetupHint(message: message, url: url))
    }

    /// The provider's CLI/credentials aren't present on this machine at all, so
    /// the user doesn't use it. The section is hidden rather than shown with an
    /// install nudge — being a single-provider user is a fully supported state.
    static func notDetected(_ name: String) -> ProviderUsage {
        ProviderUsage(name: name, pools: [], detected: false)
    }
}

enum Format {
    /// "resets in 3h 12m" / "resets in 2d 4h"
    static func relativeReset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let duration = resetDuration(date, now: now)
        return duration == "resetting…" ? duration : "resets in \(duration)"
    }

    /// Just the time-remaining part: "12m" / "3h 12m" / "2d 4h" / "resetting…".
    /// Used inline next to a window's percentage where the "resets in" prefix
    /// would cost too much width. `now` is injectable so a ticking view can
    /// recompute the countdown against the current wall clock — the reset moment
    /// is fixed, but "how long until it" isn't, and nothing in the window's value
    /// changes to prompt a redraw as time passes.
    static func resetDuration(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let secs = date.timeIntervalSince(now)
        if secs <= 0 { return "resetting…" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 { return "\(hours)h \(remMins)m" }
        let days = hours / 24
        let remHours = hours % 24
        return "\(days)d \(remHours)h"
    }

    static func percent(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }

    /// Footer freshness: "just now" / "2m ago" / "1h 5m ago" / "3d ago". Coarser
    /// than a clock time on purpose — staleness is the question it answers.
    static func updatedAgo(_ date: Date, now: Date = Date()) -> String {
        let mins = Int(now.timeIntervalSince(date) / 60)
        if mins < 1 { return "just now" }
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 {
            let remMins = mins % 60
            return remMins == 0 ? "\(hours)h ago" : "\(hours)h \(remMins)m ago"
        }
        return "\(hours / 24)d ago"
    }

    /// "3 free resets" — just the count. Short on purpose: it shares a row
    /// with a button, and a truncated line is worse than a terse one.
    static func resetCredits(_ credits: ResetCredits) -> String {
        credits.available == 1 ? "1 free reset" : "\(credits.available) free resets"
    }

    /// The caption under that count: "First expires Sep 21" / "Expires in
    /// 5h 2m". Within a day the remaining time says more than the date. Nil
    /// when the provider didn't say.
    static func resetCreditExpiry(_ credits: ResetCredits, now: Date = Date()) -> String? {
        guard let expiry = credits.earliestExpiry else { return nil }
        let which = credits.available == 1 ? "Expires" : "First expires"
        if expiry.timeIntervalSince(now) < 24 * 3600 {
            return "\(which) in \(resetDuration(expiry))"
        }
        return "\(which) \(expiry.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// The absolute reset moment for tooltips: "Resets today at 7:00 PM",
    /// "Resets tomorrow at 9:00 AM", a weekday ("Resets Sunday at 7:00 PM") for
    /// the next six calendar days — the span where a weekday is unambiguous —
    /// and an explicit date ("Resets Aug 10 at 7:00 PM") from seven days out,
    /// where the same weekday has come around again. Counted in calendar days,
    /// not elapsed seconds, so DST transitions can't shift the boundary.
    static func absoluteReset(_ date: Date, now: Date = Date()) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        let days =
            cal.dateComponents(
                [.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)
            ).day ?? 0
        switch days {
        case ...0: return "Resets today at \(time)"
        case 1: return "Resets tomorrow at \(time)"
        case ..<7: return "Resets \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        default:
            return "Resets \(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
        }
    }
}
