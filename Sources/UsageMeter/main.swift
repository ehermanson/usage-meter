import Foundation

// `UsageMeter --selftest` fetches both providers from the terminal and prints the
// result, so the data path can be validated without the menu-bar UI.
if CommandLine.arguments.contains("--selftest") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let claude = await ClaudeClient.fetch()
        let codex = await CodexClient.fetch()
        let gemini = await GeminiClient.fetch()
        let all = [claude, codex, gemini]
        for p in all {
            let planSuffix = p.plan.map { " [\($0)]" } ?? ""
            print("\(p.name)\(planSuffix):")
            for pool in p.pools {
                if let title = pool.title { print("  \(title)") }
                for w in pool.windows {
                    let reset = Format.relativeReset(w.resetAt)
                    print(
                        String(
                            format: "  %-14@ %5.1f%%  %@",
                            w.label as NSString, w.usedPercent, reset as NSString))
                }
            }
            if let err = p.error {
                print("  note: \(err)")
            }
        }
        print("--- menu bar title (per provider) ---")
        for p in all where p.hasWindows {
            let parts = p.allWindows.map { "\($0.label) \(Format.percent($0.usedPercent))" }
            print("  \(p.name)  \(parts.joined(separator: " | "))")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `UsageMeter --activity [24h|7d|30d|90d] [--now <ISO 8601>]` scans the local
// session logs and prints the Tokens/Cost tabs' figures exactly (default 7d),
// so the data path can be checked against an independent count without the
// UI. `--now` pins the range's end, for runs that must agree while the logs
// grow. Detached so the work never needs the main thread this blocks.
if let i = CommandLine.arguments.firstIndex(of: "--activity") {
    let range =
        CommandLine.arguments[safe: i + 1].flatMap(ActivityRange.init(argument:)) ?? .week
    var now: Date?
    if let n = CommandLine.arguments.firstIndex(of: "--now") {
        guard let text = CommandLine.arguments[safe: n + 1], let date = ActivityCLI.parseNow(text)
        else {
            FileHandle.standardError.write(
                Data("--now needs an ISO 8601 time, e.g. 2026-09-27T23:00:00Z\n".utf8))
            exit(2)
        }
        now = date
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached { [now] in
        await ActivityCLI.run(range: range, now: now)
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// `UsageMeter --login on|off|status` manages the login item from the terminal.
// Bundle.main resolves to the enclosing .app when run from inside its bundle.
if let i = CommandLine.arguments.firstIndex(of: "--login") {
    let action = CommandLine.arguments[safe: i + 1] ?? "status"
    switch action {
    case "on": print(LoginItem.setEnabled(true) ? "login item: enabled" : "failed to enable")
    case "off": print(LoginItem.setEnabled(false) ? "login item: disabled" : "failed to disable")
    default: print("login item: \(LoginItem.isEnabled ? "enabled" : "not enabled")")
    }
    exit(0)
}

UsageMeterApp.main()

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
