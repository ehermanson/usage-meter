import Testing

@testable import UsageMeter

@Suite("Setup detection")
struct SetupDetectionTests {
    @Test("missing-tool phrases are recognized")
    func missingTool() {
        #expect(SetupDetection.looksLikeMissingTool("spawn codex ENOENT"))
        #expect(SetupDetection.looksLikeMissingTool("command not found: node"))
        #expect(SetupDetection.looksLikeMissingTool("Claude Agent SDK not found: ..."))
        #expect(!SetupDetection.looksLikeMissingTool("Usage temporarily throttled"))
    }

    @Test("not-signed-in phrases are recognized")
    func notSignedIn() {
        #expect(SetupDetection.looksLikeNotSignedIn("Please log in to continue"))
        #expect(SetupDetection.looksLikeNotSignedIn("401 Unauthorized"))
        #expect(SetupDetection.looksLikeNotSignedIn("OAuth credentials expired"))
        #expect(!SetupDetection.looksLikeNotSignedIn("No rate-limit data in snapshot"))
    }

    @Test("needsSetup makes a calm, non-retryable, window-less provider")
    func needsSetupFactory() {
        let p = ProviderUsage.needsSetup(
            "Codex", "The Codex CLI isn't installed.", url: "https://x")
        #expect(p.setup?.message == "The Codex CLI isn't installed.")
        #expect(p.setup?.url == "https://x")
        #expect(p.error == nil)
        #expect(!p.retryable)
        #expect(!p.hasWindows)
    }
}
