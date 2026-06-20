import Foundation

/// Shared heuristics + install links for turning a raw client error into a calm,
/// actionable "needs setup" hint. Provider clients call these to decide whether a
/// failure is really a missing-dependency / signed-out state (which the user can
/// fix) rather than a transient error.
enum SetupDetection {
    static let nodeURL = "https://nodejs.org/en/download"
    static let claudeCodeURL = "https://docs.claude.com/en/docs/claude-code/setup"
    static let codexURL = "https://github.com/openai/codex"

    /// Phrases that mean "the CLI/runtime isn't installed or couldn't be launched."
    private static let missingTool = [
        "not found", "no such file", "enoent", "command not found",
        "not installed", "cannot find", "couldn't find", "could not find",
        "executable", "spawn",
    ]

    /// Phrases that mean "the tool is installed but the user isn't authenticated."
    private static let notSignedIn = [
        "not signed in", "sign in", "log in", "login", "logged in",
        "not authenticated", "unauthenticated", "unauthorized", "authorization",
        "authentication", "credential", "oauth", "401", "403", "token",
        "re-authenticate", "expired",
    ]

    static func looksLikeMissingTool(_ message: String) -> Bool {
        contains(message, anyOf: missingTool)
    }

    static func looksLikeNotSignedIn(_ message: String) -> Bool {
        contains(message, anyOf: notSignedIn)
    }

    private static func contains(_ message: String, anyOf needles: [String]) -> Bool {
        let haystack = message.lowercased()
        return needles.contains { haystack.contains($0) }
    }
}
