import Foundation

/// Fetches Claude usage the same way Relay does — through the Claude Agent SDK's
/// experimental get_usage control request — by running a small Node helper
/// (`helpers/claude-usage.mjs`) that drives the SDK and prints JSON.
///
/// The SDK reuses Claude Code's own credentials (including silent token refresh),
/// so there's no keychain parsing or token-expiry handling here.
enum ClaudeClient {
    static func fetch() async -> ProviderUsage {
        guard let node = ProcessTools.findNode() else {
            return .failed("Claude", "node not found (needed for the Claude SDK helper)")
        }
        guard let helper = findHelper() else {
            return .failed("Claude", "claude-usage.mjs helper not found")
        }

        let result: ProcessTools.Result
        do {
            result = try await ProcessTools.run(
                executable: node,
                arguments: [helper.path],
                cwd: helper.deletingLastPathComponent(),
                timeout: 40
            )
        } catch {
            return .failed("Claude", error.localizedDescription, retryable: true)
        }

        guard let line = result.stdout
            .split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let data = String(line).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("Claude", stderr.isEmpty ? "No output from SDK helper" : stderr,
                           retryable: true)
        }

        let plan = prettyPlan(root["subscription_type"] as? String)

        if (root["ok"] as? Bool) != true {
            let msg = (root["error"] as? String) ?? "Claude usage unavailable"
            let retryable = (root["code"] as? String) == "throttled"
            return .failed("Claude", msg, retryable: retryable, plan: plan)
        }

        guard let limits = root["rate_limits"] as? [String: Any] else {
            return .failed("Claude", "No rate-limit data", retryable: true, plan: plan)
        }
        return parse(limits, plan: plan)
    }

    // MARK: - Parsing (rate_limits shares the /api/oauth/usage shape)

    private static func parse(_ limits: [String: Any], plan: String?) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let w = window(limits["five_hour"], label: "5h") { windows.append(w) }
        if let w = window(limits["seven_day"], label: "7d") { windows.append(w) }
        if let w = window(limits["seven_day_opus"], label: "7d Opus") { windows.append(w) }
        if windows.isEmpty {
            return .failed("Claude", "No usage windows", retryable: true, plan: plan)
        }
        return ProviderUsage(name: "Claude", windows: windows, error: nil, plan: plan)
    }

    private static func window(_ raw: Any?, label: String) -> UsageWindow? {
        guard let dict = raw as? [String: Any],
              let util = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageWindow(label: label, usedPercent: util,
                           resetAt: isoDate(dict["resets_at"] as? String))
    }

    private static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
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

    /// Resolved in priority order: build-time path baked into Info.plist,
    /// an env override, then the known project location.
    private static func findHelper() -> URL? {
        var candidates: [String] = []
        if let baked = Bundle.main.object(forInfoDictionaryKey: "ClaudeHelperPath") as? String {
            candidates.append(baked)
        }
        if let env = ProcessInfo.processInfo.environment["USAGE_BAR_HELPER"] {
            candidates.append(env)
        }
        candidates.append("\(NSHomeDirectory())/projects/usage-bar/helpers/claude-usage.mjs")
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }
}
