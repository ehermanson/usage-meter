import Foundation
import Security
import Testing

@testable import UsageMeter

/// The bounded Keychain read that Gemini's credentials come through.
///
/// Worth covering directly because the interesting states are hard to reach in
/// normal use: the success path only runs on a machine signed into Gemini, and
/// the "unreadable" path needs an authorization prompt to be pending. Writing
/// and reading our own throwaway item exercises the first two for real — writing
/// an item we own doesn't prompt, so this is safe to run anywhere.
@Suite("Keychain read")
struct KeychainReadTests {
    private static let service = "com.erichermanson.usagemeter.tests"

    /// Tests run in parallel, so each one owns a separate item — otherwise the
    /// "missing" case reads whatever a sibling test happened to have just written.
    private func withItem(
        _ account: String, data: Data?, _ body: (String) -> Void
    ) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        if let data {
            var attributes = query
            attributes[kSecValueData as String] = data
            SecItemAdd(attributes as CFDictionary, nil)
        }
        defer { SecItemDelete(query as CFDictionary) }
        body(account)
    }

    @Test("an item we can read comes back verbatim")
    func readsStoredData() {
        let payload = Data(#"{"refresh_token":"abc"}"#.utf8)
        withItem("read-verbatim", data: payload) { account in
            let result = GeminiClient.keychainRead(service: Self.service, account: account)
            guard case .found(let data) = result else {
                Issue.record("expected .found, got \(result)")
                return
            }
            #expect(data == payload)
        }
    }

    @Test("a missing item is absent, not unavailable")
    func missingItemIsAbsent() {
        withItem("read-missing", data: nil) { account in
            // This distinction decides whether the provider is hidden as "not set
            // up on this machine" or surfaced with a fix-it hint, so it has to be
            // exact: only a genuine errSecItemNotFound may hide the section.
            #expect(GeminiClient.keychainRead(service: Self.service, account: account) == .absent)
        }
    }

    @Test("reading an item that exists is fast enough not to trip the deadline")
    func readIsWellUnderTheTimeout() {
        withItem("read-timing", data: Data("x".utf8)) { account in
            // The 2s deadline doubles as the "a dialog is up" detector, which only
            // holds if an ordinary read is orders of magnitude quicker.
            let started = Date()
            _ = GeminiClient.keychainRead(service: Self.service, account: account)
            #expect(Date().timeIntervalSince(started) < 0.5)
        }
    }
}
