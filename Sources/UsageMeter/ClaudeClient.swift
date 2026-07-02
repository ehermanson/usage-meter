import Foundation

/// Fetches Claude usage the same way Relay does — through the Claude Agent SDK's
/// experimental get_usage control request — by running a small Node helper
/// (`helpers/claude-usage.mjs`) that drives the SDK and prints JSON.
///
/// The SDK reuses Claude Code's own credentials (including silent token refresh),
/// so there's no keychain parsing or token-expiry handling here.
enum ClaudeClient {
    static func fetch() async -> ProviderUsage {
        // The Agent SDK needs a Claude Code binary to drive; the app reuses the
        // user's own install (passed to the helper via the env) rather than
        // bundling one. If it isn't installed, the user doesn't use Claude Code,
        // so hide the section entirely rather than nudge them to install it.
        guard let claude = ProcessTools.findClaude() else {
            return .notDetected("Claude")
        }
        guard let node = ProcessTools.findNode() else {
            return .needsSetup(
                "Claude", "Node.js is required to read Claude usage.",
                url: SetupDetection.nodeURL)
        }
        guard let helper = findHelper() else {
            return .failed("Claude", "Claude helper missing from the app bundle")
        }

        let result: ProcessTools.Result
        do {
            result = try await ProcessTools.run(
                executable: node,
                arguments: [helper.path],
                cwd: helper.deletingLastPathComponent(),
                extraEnv: ["USAGE_METER_CLAUDE_BIN": claude],
                timeout: 40
            )
        } catch {
            return .failed("Claude", error.localizedDescription, retryable: true)
        }

        guard
            let line = result.stdout
                .split(separator: "\n")
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
            let data = String(line).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(
                "Claude", stderr.isEmpty ? "No output from SDK helper" : stderr,
                retryable: true)
        }

        let plan = prettyPlan(root["subscription_type"] as? String)

        if (root["ok"] as? Bool) != true {
            let msg = (root["error"] as? String) ?? "Claude usage unavailable"
            let code = root["code"] as? String
            if code == "throttled" {
                return .failed("Claude", msg, retryable: true, plan: plan)
            }
            // The SDK couldn't even start (Claude Code not installed) or reported
            // an auth failure — surface a calm, fixable hint instead of a red error.
            if SetupDetection.looksLikeMissingTool(msg) {
                return .needsSetup(
                    "Claude", "Claude Code isn't installed or set up.",
                    url: SetupDetection.claudeCodeURL, plan: plan)
            }
            if SetupDetection.looksLikeNotSignedIn(msg) {
                return .needsSetup(
                    "Claude", "Sign in to Claude Code to track usage.",
                    url: SetupDetection.claudeCodeURL, plan: plan)
            }
            return .failed("Claude", msg, retryable: false, plan: plan)
        }

        guard let limits = root["rate_limits"] as? [String: Any] else {
            return .failed("Claude", "No rate-limit data", retryable: true, plan: plan)
        }
        return parse(limits, plan: plan)
    }

    // MARK: - Parsing (rate_limits shares the /api/oauth/usage shape)

    /// Friendly labels + display order for known window keys. Any other key that
    /// looks like a window (numeric `utilization` + `resets_at`) is still shown.
    private static let knownLabels: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "Weekly · all"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_oauth_apps", "Weekly · apps"),
        ("seven_day_cowork", "Weekly · cowork"),
        ("overage", "Overage"),
    ]

    /// Exposed for tests. Maps a decoded `rate_limits` dict to provider usage.
    static func parse(_ limits: [String: Any], plan: String?) -> ProviderUsage {
        var windows: [UsageWindow] = []

        // Only known, user-facing windows. The payload also carries internal
        // codenamed entries (amber_ladder, tangelo, omelette_promotional, …) that
        // become window-shaped when active but aren't real limits — an allowlist
        // keeps those from rendering as bogus rows.
        for (key, label) in knownLabels {
            if let w = window(limits[key], label: label) {
                windows.append(w)
            }
        }

        // Per-model weekly limits arrive as a `model_scoped` array (e.g. Fable),
        // separate from the null top-level `seven_day_<model>` keys — surface them
        // generically so any current or future model shows without a code change.
        // Skip any whose label a known window already produced, to avoid dupes.
        for w in modelScopedWindows(limits["model_scoped"])
        where !windows.contains(where: { $0.label == w.label }) {
            windows.append(w)
        }

        // Dollar-budget usage (Enterprise plans, or any plan with extra usage
        // enabled) reports no time windows — just a monthly spend against a limit.
        // Surface it so those users see something instead of "No usage windows".
        if let spend = spendWindow(limits["spend"]) {
            windows.append(spend)
        }

        if windows.isEmpty {
            return .failed("Claude", "No usage windows", retryable: true, plan: plan)
        }
        return .ok("Claude", pools: [UsagePool(title: nil, windows: windows)], plan: plan)
    }

    /// A window entry is a dict carrying a numeric `utilization` and `resets_at`;
    /// this skips non-window keys like `extra_usage`, `limits`, and `spend`.
    private static func window(_ raw: Any?, label: String) -> UsageWindow? {
        guard let dict = raw as? [String: Any],
            let util = (dict["utilization"] as? NSNumber)?.doubleValue,
            dict["resets_at"] is String
        else { return nil }
        return UsageWindow(
            label: label, usedPercent: util,
            resetAt: isoDate(dict["resets_at"] as? String))
    }

    /// Per-model weekly limits arrive as `model_scoped`: an array of
    /// `{ display_name, utilization, resets_at }` (utilization 0-100). Each becomes
    /// a "Weekly · <model>" window — e.g. Fable → "Weekly · Fable".
    private static func modelScopedWindows(_ raw: Any?) -> [UsageWindow] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { entry in
            guard let dict = entry as? [String: Any],
                let name = (dict["display_name"] as? String), !name.isEmpty,
                let util = (dict["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return UsageWindow(
                label: "Weekly · \(name)", usedPercent: util,
                resetAt: isoDate(dict["resets_at"] as? String))
        }
    }

    /// The `spend` entry is a monthly dollar budget (used vs limit), not a time
    /// window — shown only when enabled, with the dollar amounts as the caption.
    private static func spendWindow(_ raw: Any?) -> UsageWindow? {
        guard let dict = raw as? [String: Any],
            (dict["enabled"] as? Bool) == true,
            let percent = (dict["percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let detail: String?
        if let used = money(dict["used"]), let limit = money(dict["limit"]) {
            detail = "\(used) / \(limit)"
        } else {
            detail = nil
        }
        return UsageWindow(label: "Usage", usedPercent: percent, resetAt: nil, detail: detail)
    }

    /// Formats a `{amount_minor, currency, exponent}` money object as a whole-unit
    /// currency string, e.g. `{23731, USD, 2}` → "$237".
    private static func money(_ raw: Any?) -> String? {
        guard let dict = raw as? [String: Any],
            let minor = (dict["amount_minor"] as? NSNumber)?.doubleValue,
            let exponent = (dict["exponent"] as? NSNumber)?.intValue
        else { return nil }
        let code = (dict["currency"] as? String) ?? "USD"
        let amount = minor / pow(10, Double(exponent))
        return amount.formatted(.currency(code: code).precision(.fractionLength(0)))
    }

    // Formatters are expensive to build, so reuse them across windows.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func prettyPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        default: return raw.capitalized
        }
    }

    // MARK: - Locate the helper script

    /// Resolved in priority order:
    ///   1. the copy bundled inside the .app (`Resources/helpers/`) — the shipping
    ///      path, self-contained with its own `node_modules`;
    ///   2. an env override (`USAGE_METER_HELPER`) for development;
    ///   3. a legacy Info.plist baked path, then the project checkout — so
    ///      `swift run` from a dev tree still works without a bundle.
    private static func findHelper() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("helpers/claude-usage.mjs").path
        {
            candidates.append(bundled)
        }
        if let env = ProcessInfo.processInfo.environment["USAGE_METER_HELPER"] {
            candidates.append(env)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "ClaudeHelperPath") as? String {
            candidates.append(baked)
        }
        candidates.append("\(NSHomeDirectory())/projects/usage-meter/helpers/claude-usage.mjs")
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }
}
