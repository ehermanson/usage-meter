import Foundation

/// Fetches Claude usage from the OAuth usage endpoint, authenticating with the
/// token Claude Code stores in the macOS keychain ("Claude Code-credentials").
enum ClaudeClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch() async -> ProviderUsage {
        guard let token = readToken() else {
            return .failed("Claude", "No Claude token in keychain")
        }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return .failed("Claude", "No HTTP response")
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 401 {
                    return .failed("Claude", "Token expired — open Claude Code to refresh")
                }
                return .failed("Claude", "HTTP \(http.statusCode)")
            }
            return parse(data)
        } catch {
            return .failed("Claude", error.localizedDescription)
        }
    }

    private static func parse(_ data: Data) -> ProviderUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("Claude", "Bad JSON")
        }
        var windows: [UsageWindow] = []
        if let w = window(from: root["five_hour"], label: "5h") { windows.append(w) }
        if let w = window(from: root["seven_day"], label: "7d") { windows.append(w) }
        // Optional scoped weekly pools, if present and non-null.
        if let w = window(from: root["seven_day_opus"], label: "7d Opus") { windows.append(w) }
        if windows.isEmpty {
            return .failed("Claude", "No usage data")
        }
        return ProviderUsage(name: "Claude", windows: windows, error: nil)
    }

    private static func window(from raw: Any?, label: String) -> UsageWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let util = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let reset = isoDate(dict["resets_at"] as? String)
        return UsageWindow(label: label, usedPercent: util, resetAt: reset)
    }

    private static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// Reads the OAuth access token from the keychain via the `security` CLI.
    private static func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }
}
