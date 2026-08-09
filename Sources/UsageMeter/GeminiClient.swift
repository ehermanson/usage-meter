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

    // Our own Keychain item, where we copy the credentials we read from a sign-in
    // tool. We own this item, so reading it never prompts and — unlike the tools'
    // items, which their CLIs delete-and-recreate on every token refresh (which
    // resets the access list and re-triggers the "allow access" prompt) — it stays
    // trusted across refreshes. This is what stops the recurring Keychain prompt.
    private static let ownService = Bundle.main.bundleIdentifier ?? "com.erichermanson.usagemeter"
    private static let ownAccount = "gemini-oauth"

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
            guard let fraction = Parse.num(bucket["remainingFraction"]) else { continue }
            guard let reset = Parse.isoDate(bucket["resetTime"] as? String),
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
        let project = try await deriveProject(token: token)
        remember(project)
        return project
    }

    /// Asks loadCodeAssist which project this account's usage hangs off,
    /// bypassing the cache. Some accounts legitimately have none.
    private static func deriveProject(token: String) async throws -> String {
        let json = try await post(
            "loadCodeAssist", token: token,
            body: ["metadata": ["pluginType": "GEMINI"]])
        guard let project = json["cloudaicompanionProject"] as? String, !project.isEmpty else {
            throw GeminiError("No Code Assist project for this account")
        }
        return project
    }

    private static func remember(_ project: String) {
        cachedProject = project
        UserDefaults.standard.set(project, forKey: projectKey)
    }

    private static func retrieveQuota(
        token: String, project: String
    ) async throws -> [[String: Any]] {
        do {
            let json = try await post("retrieveUserQuota", token: token, body: ["project": project])
            return json["buckets"] as? [[String: Any]] ?? []
        } catch let error as GeminiError {
            // The cached project belongs to whichever account/tool was signed in
            // when it was fetched, so a 4xx refusal may mean it's stale (the
            // user switched accounts or sign-in tools). Recover by asking
            // loadCodeAssist for the current project — but only ever *replace*
            // the cache with a better answer, never clear it outright. Some
            // accounts have no project at all, so a clear on what turns out to
            // be a transient refusal is a one-way door: with the cache gone
            // there is nothing left to retry, permanently. 401 is about the
            // token and 5xx/network about nothing — no re-derive for those.
            guard let status = error.status, (400..<500).contains(status), status != 401,
                let fresh = try? await deriveProject(token: token), fresh != project
            else { throw error }
            remember(fresh)
            let json = try await post("retrieveUserQuota", token: token, body: ["project": fresh])
            return json["buckets"] as? [[String: Any]] ?? []
        }
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
            // 401 (a refresh fixes it next tick), 429 (rate limit), and 5xx are
            // moments, not verdicts — retryable keeps the last good snapshot on
            // screen instead of wiping it over one of them.
            throw GeminiError(
                message ?? "Gemini API error \(code)",
                retryable: code == 401 || code == 429 || code >= 500,
                status: code)
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
        awaitingKeychainApproval = false
        let refresher: (Credentials, String) async throws -> (value: String, expiry: Date) = {
            creds, refreshToken in
            try await refresh(
                token: refreshToken, clientID: creds.clientID, clientSecret: creds.clientSecret)
        }
        // Prefer the credentials we've copied into our own item: reading it
        // doesn't prompt, so steady-state refreshes never touch a sign-in tool's
        // Keychain item. Fall through only if our stored refresh token has been
        // rejected (the user revoked access or re-signed-in elsewhere).
        if let mine = ownCredentials() {
            if let token = try? await selectToken(from: [mine], now: Date(), refresh: refresher) {
                cachedToken = (token.value, token.expiry)
                return token.value
            }
        }
        let candidates = sources.compactMap { $0() }
        // No candidates *and* a read still sitting behind an approval dialog is
        // a different story from no candidates at all: the credentials probably
        // do exist, they just can't be read until someone answers. Say that,
        // rather than reporting a timeout the user can't act on — or worse,
        // deciding Gemini isn't set up and hiding the section outright.
        if candidates.isEmpty, awaitingKeychainApproval {
            throw GeminiError(
                "Needs Keychain access to read your Gemini sign-in. "
                    + "Approve the macOS prompt, or allow Usage Meter in Keychain Access.",
                retryable: true, setupNeeded: true)
        }
        let token = try await selectToken(from: candidates, now: Date(), refresh: refresher)
        cachedToken = (token.value, token.expiry)
        // Copy the *winning* source's refresh token into our own item so the next
        // refresh — and every one after — reads from there instead of re-prompting
        // for the tool's item. It must be the source that produced this token: a
        // sibling source whose refresh just failed would only seed our item with
        // a dead token that every later fetch retries first.
        if token.source.refreshToken != nil {
            storeOwnCredentials(token.source, accessToken: token.value, expiry: token.expiry)
        }
        return token.value
    }

    /// Returns the first usable token across `candidates` — a still-valid access
    /// token, or a successful refresh — along with the source credentials that
    /// produced it (so only the winner's refresh token gets persisted). A
    /// candidate that's expired with no refresh token (or whose refresh fails) is
    /// skipped so a later source can still win — this is what makes a stale
    /// Antigravity login fall through to the Gemini CLI.
    /// Pure but for the injected `refresh`, so the fallback order is testable.
    static func selectToken(
        from candidates: [Credentials],
        now: Date,
        refresh: (_ creds: Credentials, _ refreshToken: String) async throws
            -> (value: String, expiry: Date)
    ) async throws -> (value: String, expiry: Date, source: Credentials) {
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
                return (creds.accessToken, expiry, creds)
            }
            guard let refreshToken = creds.refreshToken else {
                lastError = GeminiError(
                    "Gemini sign-in expired — re-authenticate in your sign-in tool.",
                    retryable: false, setupNeeded: true)
                continue
            }
            do {
                let refreshed = try await refresh(creds, refreshToken)
                return (refreshed.value, refreshed.expiry, creds)
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
        let expiresIn = Parse.num(json["expires_in"]) ?? 3600
        return (access, Date().addingTimeInterval(expiresIn))
    }

    /// Outcome of a Keychain read. `awaitingApproval` is the case worth naming:
    /// the item is there, but macOS is holding the read behind an authorization
    /// dialog nobody has answered. It looks identical to "missing" from the
    /// return value alone, and telling them apart is the difference between a
    /// row that says "timed out" and one that says what to actually do.
    enum KeychainRead: Equatable {
        case found(Data)
        /// `errSecItemNotFound` — the sign-in genuinely isn't on this machine.
        case absent
        /// The item is there but unreadable: a prompt nobody answered, or access
        /// refused. Distinct from `absent` because it must *not* be read as "the
        /// user doesn't use Gemini" — that hides the section and explains nothing.
        case unavailable
    }

    /// Reads a Keychain item, giving up if the read doesn't return promptly.
    ///
    /// A local Keychain read is sub-millisecond; the *only* thing that makes one
    /// take seconds is an authorization prompt waiting on the user. So a short
    /// deadline here is a reliable detector rather than a guess, and it doubles
    /// as protection against `SecItemCopyMatching` blocking forever — it isn't
    /// cancellable, so the abandoned read is left to finish on its own.
    static func keychainRead(service: String, account: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let done = DispatchSemaphore(value: 0)
        let result = ReadBox()
        DispatchQueue.global(qos: .userInitiated).async {
            var item: CFTypeRef?
            result.status = SecItemCopyMatching(query as CFDictionary, &item)
            result.data = item as? Data
            done.signal()
        }
        guard done.wait(timeout: .now() + keychainTimeout) == .success else {
            awaitingKeychainApproval = true
            return .unavailable
        }
        if result.status == errSecSuccess, let data = result.data {
            return .found(data)
        }
        // Only a genuine "no such item" means Gemini isn't set up here. Anything
        // else — access denied, interaction not allowed, a cancelled prompt — is
        // a readable item we were refused, and saying so beats disappearing.
        guard result.status == errSecItemNotFound else {
            awaitingKeychainApproval = true
            return .unavailable
        }
        return .absent
    }

    /// A normal Keychain read is sub-millisecond. Anything approaching this is an
    /// authorization dialog waiting on the user, so the deadline doubles as the
    /// detector — generous by three orders of magnitude, still quick to give up.
    private static let keychainTimeout: TimeInterval = 2

    /// Set when any read in the current attempt gave up waiting on a dialog, so
    /// `accessToken()` can tell "no credentials here" from "can't get at them
    /// yet". Reset at the start of each attempt rather than accumulating.
    private static var awaitingKeychainApproval = false

    /// Carries the read across the semaphore hand-off.
    private final class ReadBox: @unchecked Sendable {
        var status: OSStatus = errSecSuccess
        var data: Data?
    }

    /// Antigravity CLI: macOS Keychain item (service "gemini", account
    /// "antigravity"), a `go-keyring-base64:`-prefixed base64 of JSON
    /// `{ "token": { access_token, refresh_token, expiry } }`. The first read
    /// prompts the user to grant Keychain access (the item is owned by the CLI).
    private static func antigravityCredentials() -> Credentials? {
        guard case .found(let data) = keychainRead(service: "gemini", account: "antigravity"),
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
            expiry: Parse.isoDate(token["expiry"] as? String),
            clientID: OAuthClient.antigravity.id,
            clientSecret: OAuthClient.antigravity.secret)
    }

    /// Reads the credentials we previously copied into our own Keychain item.
    ///
    /// Normally trusted and prompt-free, since we created the item — but the ACL
    /// is bound to the code signature, so a re-signed build (any dev rebuild, and
    /// in principle a re-signed release) reads as a different app and gets the
    /// prompt anyway. Bounded for exactly that reason.
    private static func ownCredentials() -> Credentials? {
        guard case .found(let data) = keychainRead(service: ownService, account: ownAccount),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let refresh = json["refresh_token"] as? String,
            let clientID = json["client_id"] as? String,
            let clientSecret = json["client_secret"] as? String
        else { return nil }
        return Credentials(
            accessToken: json["access_token"] as? String ?? "",
            refreshToken: refresh,
            expiry: Parse.isoDate(json["expiry"] as? String),
            clientID: clientID,
            clientSecret: clientSecret)
    }

    /// Upserts the given credentials (refresh token + issuing client, plus the
    /// freshest access token) into our own Keychain item. Writing our own item
    /// doesn't prompt, and `kSecAttrAccessibleAfterFirstUnlock` keeps it readable
    /// for background refreshes while the screen is locked.
    private static func storeOwnCredentials(
        _ creds: Credentials, accessToken: String, expiry: Date
    ) {
        guard let refresh = creds.refreshToken,
            let data = try? JSONSerialization.data(withJSONObject: [
                "refresh_token": refresh,
                "client_id": creds.clientID,
                "client_secret": creds.clientSecret,
                "access_token": accessToken,
                "expiry": Parse.isoString(expiry),
            ])
        else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: ownAccount,
        ]
        let status = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
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
        if let ms = Parse.num(json["expiry_date"]) {
            expiry = Date(timeIntervalSince1970: ms / 1000)
        } else if let s = json["expiry"] as? String {
            expiry = Parse.isoDate(s)
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
        /// The HTTP status this came from, when it came from one at all — lets a
        /// caller tell "the API refused this argument" from "the network failed".
        let status: Int?
        init(
            _ message: String, retryable: Bool = true, setupNeeded: Bool = false,
            notDetected: Bool = false, status: Int? = nil
        ) {
            self.message = message
            self.retryable = retryable
            self.setupNeeded = setupNeeded
            self.notDetected = notDetected
            self.status = status
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
}
