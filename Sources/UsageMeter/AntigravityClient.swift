import Foundation

/// Fetches Antigravity usage by running `agy -p "/usage" --output-format json`.
///
/// Print-mode `/usage` is read-only and non-interactive: it answers using `agy`'s
/// own sign-in (so Usage Meter never touches the macOS Keychain), without
/// starting an agent turn, spending quota, or leaving a conversation behind.
enum AntigravityClient {
    private static let providerName = "Antigravity"

    static func fetch() async -> ProviderUsage {
        guard let agy = ProcessTools.findAntigravity() else {
            // The Antigravity CLI isn't installed — the user doesn't use it, so
            // hide the section entirely instead of nudging them to install it.
            return .notDetected(providerName)
        }
        let result: ProcessTools.Result
        do {
            result = try await ProcessTools.run(
                executable: agy,
                arguments: ["--log-file", "/dev/null", "-p", "/usage", "--output-format", "json"],
                extraEnv: ["AGY_CLI_DISABLE_AUTO_UPDATE": "1"],
                timeout: 30
            )
        } catch {
            return .failed(providerName, error.localizedDescription, retryable: true)
        }
        return parseCommandResult(
            stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }

    // MARK: - Parsing (pure; unit-tested)

    private static let fiveHours: TimeInterval = 5 * 3600
    private static let oneDay: TimeInterval = 24 * 3600
    private static let sevenDays: TimeInterval = 7 * 24 * 3600

    /// Interprets the finished `agy -p "/usage" --output-format json` process output.
    static func parseCommandResult(
        stdout: String, stderr: String, exitCode: Int32, now: Date = .now
    ) -> ProviderUsage {
        let trimmedOut = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedErr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        // Even on non-zero exit (e.g. exit 2 for GEMINI_API_KEY), agy may emit
        // a JSON object describing the error; try decoding stdout first.
        if let root = decodeJSON(trimmedOut) {
            let status = (root["status"] as? String)?.uppercased()
            if exitCode == 0, status == nil || status == "SUCCESS" {
                return parse(root, now: now)
            }
            let message =
                extractErrorMessage(from: root, includeResponse: true)
                ?? firstNonEmpty(trimmedErr, trimmedOut)
            return classifyFailure(message: message, exitCode: exitCode, structured: true)
        }

        let message = firstNonEmpty(trimmedErr, trimmedOut)
        if exitCode != 0 {
            return classifyFailure(message: message, exitCode: exitCode, structured: false)
        }
        return .failed(
            providerName,
            message.isEmpty ? "No output from agy" : message,
            retryable: true)
    }

    /// Parses the decoded JSON root of `agy -p "/usage" --output-format json`.
    /// Shape: `{ status, command: { name: "usage", data: { groups: [{ name, buckets: [...] }] } } }`.
    static func parse(_ root: [String: Any], now: Date = .now) -> ProviderUsage {
        let command = root["command"] as? [String: Any]
        let data = (command?["data"] as? [String: Any]) ?? (root["data"] as? [String: Any])
        guard let rawGroups = data?["groups"] as? [[String: Any]] else {
            // Only read an explicit `error` field here — on SUCCESS, `response`
            // holds the plain-text usage table rather than an error message.
            if let message = extractErrorMessage(from: root, includeResponse: false) {
                return classifyFailure(message: message, exitCode: 0, structured: true)
            }
            return .failed(providerName, "No quota data", retryable: true)
        }

        var parsedGroups: [(name: String?, windows: [UsageWindow])] = []
        for group in rawGroups {
            guard let rawBuckets = group["buckets"] as? [[String: Any]] else { continue }
            var entries: [(window: UsageWindow, order: Int)] = []
            for (index, bucket) in rawBuckets.enumerated() {
                let resetAt = Parse.isoDate(bucket["reset_time"] as? String)
                // Go/protobuf JSON encoders omit zero-valued floats, so an
                // exhausted bucket may omit `remaining_fraction` altogether.
                // Treat a missing fraction as 0% remaining (100% used) only
                // when the bucket carries a `window` and a future `reset_time`.
                let fraction: Double
                if let parsed = Parse.num(bucket["remaining_fraction"]) {
                    fraction = parsed
                } else if let window = bucket["window"] as? String, !window.isEmpty,
                    let resetAt, resetAt > now
                {
                    fraction = 0
                } else {
                    continue
                }
                // Skip locked/placeholder buckets carrying an epoch (1970) reset.
                if let resetAt, resetAt.timeIntervalSince1970 <= 0, fraction <= 0 { continue }

                let usedPercent = max(0, min(100, (1 - fraction) * 100))
                let (label, duration) = windowMetadata(for: bucket)
                let window = UsageWindow(
                    label: label,
                    usedPercent: usedPercent,
                    resetAt: resetAt,
                    duration: duration)
                entries.append((window, index))
            }

            // Show shorter windows first (5h, then Daily, then Weekly) to match
            // Claude and Codex, keeping relative order for unknown spans.
            entries.sort { lhs, rhs in
                let lDur = lhs.window.duration ?? .greatestFiniteMagnitude
                let rDur = rhs.window.duration ?? .greatestFiniteMagnitude
                if lDur != rDur { return lDur < rDur }
                return lhs.order < rhs.order
            }

            // Deduplicate labels within a pool: keep the higher usage (and sooner
            // reset on a tie) so `UsageWindow.id` stays unique in SwiftUI lists.
            var windows: [UsageWindow] = []
            for entry in entries {
                if let existingIndex = windows.firstIndex(where: { $0.label == entry.window.label })
                {
                    let existing = windows[existingIndex]
                    if entry.window.usedPercent > existing.usedPercent
                        || (entry.window.usedPercent == existing.usedPercent
                            && (entry.window.resetAt ?? .distantFuture)
                                < (existing.resetAt ?? .distantFuture))
                    {
                        windows[existingIndex] = entry.window
                    }
                } else {
                    windows.append(entry.window)
                }
            }

            guard !windows.isEmpty else { continue }
            let rawName = (group["name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let name = rawName.flatMap { $0.isEmpty ? nil : $0 }
            parsedGroups.append((name: name, windows: windows))
        }

        guard !parsedGroups.isEmpty else {
            return .failed(providerName, "No available quota", retryable: true)
        }

        // Always keep the primary pool; hide secondary pools (e.g. third-party
        // models, separate Argon quota) while they display as 0% used (< 0.5%),
        // surfacing them as soon as any window in them shows usage.
        let visibleGroups = parsedGroups.enumerated().compactMap { index, group in
            index == 0 || group.windows.contains(where: { $0.usedPercent >= 0.5 }) ? group : nil
        }

        let singlePool = visibleGroups.count == 1
        let pools = visibleGroups.map { group in
            UsagePool(title: singlePool ? nil : group.name, windows: group.windows)
        }
        return .ok(providerName, pools: pools)
    }

    private static func windowMetadata(
        for bucket: [String: Any]
    ) -> (label: String, duration: TimeInterval?) {
        let windowKey =
            (bucket["window"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch windowKey {
        case "5h", "5hr", "five_hour", "five-hour":
            return ("5h", fiveHours)
        case "daily", "day", "24h", "1d":
            return ("Daily", oneDay)
        case "weekly", "week", "7d":
            return ("Weekly", sevenDays)
        default:
            break
        }

        // Fall back to the bucket's name or id if `window` is missing or new.
        let id = (bucket["id"] as? String)?.lowercased() ?? ""
        let name = (bucket["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let combined = "\(id) \(name.lowercased())"
        if combined.contains("5h") || combined.contains("five hour") || combined.contains("5-hour")
        {
            return ("5h", fiveHours)
        }
        if combined.contains("week") || combined.contains("7d") {
            return ("Weekly", sevenDays)
        }
        if combined.contains("daily") || combined.contains("24h") {
            return ("Daily", oneDay)
        }
        if !name.isEmpty { return (name, nil) }
        if !windowKey.isEmpty { return (windowKey.capitalized, nil) }
        return ("Usage", nil)
    }

    /// Transport failures (DNS, dial timeout, proxy hiccup) must stay retryable
    /// even when the surrounding message mentions "token" (e.g. "failed to
    /// refresh token: dial tcp: i/o timeout"), so `lastGood` isn't wiped.
    private static let transportPhrases = [
        "dial tcp", "i/o timeout", "timed out", "timeout", "connection refused",
        "connection reset", "no such host", "network is unreachable", "tls handshake",
        "temporary failure", "eof",
    ]

    /// Unstructured stderr messages that unambiguously mean the user is signed
    /// out (narrower than `SetupDetection.looksLikeNotSignedIn`, which also
    /// matches loose words like "token" or "403").
    private static let explicitSignInPhrases = [
        "authentication required", "authentication expired", "not signed in",
        "please sign in", "please log back in", "not authenticated",
        "unauthenticated", "no saved login", "no credentials",
    ]

    private static func classifyFailure(
        message: String, exitCode: Int32, structured: Bool
    ) -> ProviderUsage {
        let lower = message.lowercased()
        let isTransport = transportPhrases.contains { lower.contains($0) }
        if !isTransport {
            if (structured || exitCode == 2),
                lower.contains("gemini_api_key") || lower.contains("api key")
                    || lower.contains("no account quota")
            {
                return .needsSetup(
                    providerName,
                    "Sign in to Antigravity with a Google account to track usage.",
                    url: SetupDetection.antigravityURL)
            }
            if (structured && SetupDetection.looksLikeNotSignedIn(message))
                || explicitSignInPhrases.contains(where: { lower.contains($0) })
            {
                return .needsSetup(
                    providerName,
                    "Sign in to Antigravity to track usage.",
                    url: SetupDetection.antigravityURL)
            }
        }
        let fallback =
            message.isEmpty ? "Antigravity exited with status \(exitCode)" : message
        return .failed(providerName, fallback, retryable: true)
    }

    private static func decodeJSON(_ text: String) -> [String: Any]? {
        guard !text.isEmpty else { return nil }
        if let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return root
        }
        // Fallback: strip any preface/trailing lines (handles both single-line
        // and pretty-printed JSON objects).
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
            let data = String(text[start...end]).data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return root
        }
        return nil
    }

    private static func extractErrorMessage(
        from root: [String: Any], includeResponse: Bool
    ) -> String? {
        if let err = root["error"] as? String, !err.isEmpty { return err }
        if let err = root["error"] as? [String: Any] {
            for key in ["message", "userErrorMessage", "shortError", "error"] {
                if let text = err[key] as? String, !text.isEmpty { return text }
            }
        }
        if includeResponse, let response = root["response"] as? String {
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func firstNonEmpty(_ a: String, _ b: String) -> String {
        !a.isEmpty ? a : b
    }
}
