import Foundation
import Security

/// Fetches Gemini usage from the Code Assist backend that the Antigravity CLI
/// ("agy") talks to. It reuses the CLI's stored OAuth credentials from the macOS
/// Keychain (service "gemini", account "antigravity") — refreshing the access
/// token when it has expired — then makes two calls:
///   1. loadCodeAssist     → the account's auto-provisioned cloudaicompanion project
///   2. retrieveUserQuota  → per-model request buckets (remainingFraction + resetTime)
///
/// Free-tier accounts get a shared daily request budget; models that aren't part
/// of the tier come back as `remainingFraction 0` with an epoch (1970) reset and
/// are skipped rather than shown as fully used.
enum GeminiClient {
    private static let providerName = "Gemini"
    private static let base = "https://cloudcode-pa.googleapis.com/v1internal"
    private static let tokenURL = "https://oauth2.googleapis.com/token"

    // Installed-app OAuth clients for each sign-in tool we read credentials from.
    // Installed-app secrets are not confidential (they ship inside the distributed
    // binaries); refresh tokens are bound to the client that issued them, so each
    // source must refresh with its own client.
    private enum OAuthClient {
        static let antigravity = (
            id: "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com",
            secret: "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"
        )
        static let geminiCLI = (
            id: "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com",
            secret: "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"
        )
    }

    // Cached for the app's lifetime to avoid a Keychain read / refresh on every
    // tick. The project id is stable per account, so it's also persisted.
    private static var cachedToken: (value: String, expiry: Date)?
    private static var cachedProject: String?
    private static let projectKey = "geminiProject.v1"

    static func fetch() async -> ProviderUsage {
        do {
            let token = try await accessToken()
            let project = try await project(token: token)
            let buckets = try await retrieveQuota(token: token, project: project)
            return parse(buckets)
        } catch let error as GeminiError {
            if error.notDetected {
                return .notDetected(providerName)
            }
            if error.setupNeeded {
                return .needsSetup(providerName, error.message)
            }
            return .failed(providerName, error.message, retryable: error.retryable)
        } catch {
            return .failed(providerName, error.localizedDescription, retryable: true)
        }
    }

    // MARK: - Parsing (pure; unit-tested)

    /// Collapses the per-model buckets into a single "Daily" window: the free
    /// tier is a shared daily request budget, so we surface how close the most
    /// consumed available model is to its limit. Locked/epoch buckets are skipped.
    static func parse(_ buckets: [[String: Any]]) -> ProviderUsage {
        var maxUsed = 0.0
        var soonestReset: Date?
        var available = false

        for bucket in buckets {
            guard let fraction = num(bucket["remainingFraction"]) else { continue }
            guard let reset = isoDate(bucket["resetTime"] as? String),
                reset.timeIntervalSinceNow > 0
            else { continue }  // skip locked/epoch
            available = true
            maxUsed = max(maxUsed, (1 - fraction) * 100)
            if soonestReset == nil || reset < soonestReset! { soonestReset = reset }
        }

        guard available else {
            return .failed(providerName, "No available quota", retryable: true)
        }
        let window = UsageWindow(
            label: "Daily",
            usedPercent: max(0, min(100, maxUsed)),
            resetAt: soonestReset)
        return .ok(providerName, pools: [UsagePool(title: nil, windows: [window])])
    }

    // MARK: - API calls

    private static func project(token: String) async throws -> String {
        if let cachedProject { return cachedProject }
        if let saved = UserDefaults.standard.string(forKey: projectKey) {
            cachedProject = saved
            return saved
        }
        let json = try await post(
            "loadCodeAssist", token: token,
            body: ["metadata": ["pluginType": "GEMINI"]])
        guard let project = json["cloudaicompanionProject"] as? String, !project.isEmpty else {
            throw GeminiError("No Code Assist project for this account")
        }
        cachedProject = project
        UserDefaults.standard.set(project, forKey: projectKey)
        return project
    }

    private static func retrieveQuota(
        token: String, project: String
    ) async throws -> [[String: Any]] {
        do {
            let json = try await post("retrieveUserQuota", token: token, body: ["project": project])
            return json["buckets"] as? [[String: Any]] ?? []
        } catch {
            // The cached project belongs to whichever account/tool was signed in
            // when it was fetched. If it no longer matches the current token (the
            // user switched accounts or sign-in tools), the call fails here — drop
            // it so the next fetch re-derives the project via loadCodeAssist.
            clearProjectCache()
            throw error
        }
    }

    private static func clearProjectCache() {
        cachedProject = nil
        UserDefaults.standard.removeObject(forKey: projectKey)
    }

    private static func post(
        _ method: String, token: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(base):\(method)") else {
            throw GeminiError("Bad Gemini URL", retryable: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { cachedToken = nil }  // force a refresh next time
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw GeminiError(
                message ?? "Gemini API error \(code)",
                retryable: code == 401 || code >= 500)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - OAuth (multi-source)

    /// Credentials from one sign-in tool, including which OAuth client must be
    /// used to refresh them (refresh tokens are bound to their issuing client).
    /// Internal so the selection logic can be exercised in tests.
    struct Credentials {
        let accessToken: String
        let refreshToken: String?
        let expiry: Date?
        let clientID: String
        let clientSecret: String
    }

    /// Credential sources, tried in priority order. The first tool whose token is
    /// usable wins — so Gemini usage shows up regardless of whether you signed in
    /// through Antigravity or the Gemini CLI.
    private static let sources: [() -> Credentials?] = [
        antigravityCredentials, geminiCLICredentials,
    ]

    private static func accessToken() async throws -> String {
        if let cachedToken, cachedToken.expiry.timeIntervalSinceNow > 120 {
            return cachedToken.value
        }
        let candidates = sources.compactMap { $0() }
        let token = try await selectToken(from: candidates, now: Date()) { creds, refreshToken in
            try await refresh(
                token: refreshToken, clientID: creds.clientID, clientSecret: creds.clientSecret)
        }
        cachedToken = token
        return token.value
    }

    /// Returns the first usable token across `candidates`: a still-valid access
    /// token, or a successful refresh. A candidate that's expired with no refresh
    /// token (or whose refresh fails) is skipped so a later source can still win —
    /// this is what makes a stale Antigravity login fall through to the Gemini CLI.
    /// Pure but for the injected `refresh`, so the fallback order is testable.
    static func selectToken(
        from candidates: [Credentials],
        now: Date,
        refresh: (_ creds: Credentials, _ refreshToken: String) async throws
            -> (value: String, expiry: Date)
    ) async throws -> (value: String, expiry: Date) {
        guard !candidates.isEmpty else {
            // No credentials from any sign-in tool means Gemini isn't set up on
            // this machine — the user doesn't use it, so hide the section.
            throw GeminiError(
                "Gemini isn't set up on this machine.",
                retryable: false, notDetected: true)
        }
        var lastError: Error?
        for creds in candidates {
            if let expiry = creds.expiry, expiry.timeIntervalSince(now) > 120 {
                return (creds.accessToken, expiry)
            }
            guard let refreshToken = creds.refreshToken else {
                lastError = GeminiError(
                    "Gemini sign-in expired — re-authenticate in your sign-in tool.",
                    retryable: false, setupNeeded: true)
                continue
            }
            do {
                return try await refresh(creds, refreshToken)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GeminiError("Gemini authentication failed")
    }

    private static func refresh(
        token refreshToken: String, clientID: String,
        clientSecret: String
    ) async throws -> (value: String, expiry: Date) {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else {
            throw GeminiError("Gemini token refresh failed")
        }
        let expiresIn = num(json["expires_in"]) ?? 3600
        return (access, Date().addingTimeInterval(expiresIn))
    }

    /// Antigravity CLI: macOS Keychain item (service "gemini", account
    /// "antigravity"), a `go-keyring-base64:`-prefixed base64 of JSON
    /// `{ "token": { access_token, refresh_token, expiry } }`. The first read
    /// prompts the user to grant Keychain access (the item is owned by the CLI).
    private static func antigravityCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            var string = String(data: data, encoding: .utf8)
        else { return nil }
        let prefix = "go-keyring-base64:"
        if string.hasPrefix(prefix) { string.removeFirst(prefix.count) }
        guard let decoded = Data(base64Encoded: string),
            let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
            let token = json["token"] as? [String: Any],
            let access = token["access_token"] as? String
        else { return nil }
        return Credentials(
            accessToken: access,
            refreshToken: token["refresh_token"] as? String,
            expiry: isoDate(token["expiry"] as? String),
            clientID: OAuthClient.antigravity.id,
            clientSecret: OAuthClient.antigravity.secret)
    }

    /// Gemini CLI (@google/gemini-cli): plain JSON at `~/.gemini/oauth_creds.json`
    /// with `{ access_token, refresh_token, expiry_date }` (expiry in ms epoch).
    private static func geminiCLICredentials() -> Credentials? {
        let path = "\(NSHomeDirectory())/.gemini/oauth_creds.json"
        guard let data = FileManager.default.contents(atPath: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String
        else { return nil }
        var expiry: Date?
        if let ms = num(json["expiry_date"]) {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let s = json["expiry"] as? String {
            expiry = isoDate(s)
        }
        return Credentials(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiry: expiry,
            clientID: OAuthClient.geminiCLI.id,
            clientSecret: OAuthClient.geminiCLI.secret)
    }

    // MARK: - Helpers

    private struct GeminiError: Error {
        let message: String
        let retryable: Bool
        /// True when the failure is a fixable setup state (e.g. an expired sign-in)
        /// rather than a transient API error — shown as a calm hint.
        let setupNeeded: Bool
        /// True when no credentials were found at all: Gemini isn't set up on this
        /// machine, so its section is hidden rather than shown with a hint.
        let notDetected: Bool
        init(
            _ message: String, retryable: Bool = true, setupNeeded: Bool = false,
            notDetected: Bool = false
        ) {
            self.message = message
            self.retryable = retryable
            self.setupNeeded = setupNeeded
            self.notDetected = notDetected
        }
    }

    /// Percent-encodes form values so reserved characters in tokens/secrets (e.g.
    /// `+`, `/`, `=`) survive `application/x-www-form-urlencoded` transport.
    private static func formEncode(_ pairs: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")  // RFC 3986 unreserved
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        return pairs.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&")
    }

    private static func num(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

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
}
