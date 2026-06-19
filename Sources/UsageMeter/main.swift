import Foundation

// `UsageMeter --selftest` fetches both providers from the terminal and prints the
// result, so the data path can be validated without the menu-bar UI.
if CommandLine.arguments.contains("--selftest") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let claude = await ClaudeClient.fetch()
        let codex = await CodexClient.fetch()
        for p in [claude, codex] {
            let planSuffix = p.plan.map { " [\($0)]" } ?? ""
            print("\(p.name)\(planSuffix):")
            for pool in p.pools {
                if let title = pool.title { print("  \(title)") }
                for w in pool.windows {
                    let reset = Format.relativeReset(w.resetAt)
                    print(String(format: "  %-14@ %5.1f%%  %@",
                                 w.label as NSString, w.usedPercent, reset as NSString))
                }
            }
            if let err = p.error {
                print("  note: \(err)")
            }
        }
        print("--- menu bar title (per provider) ---")
        for p in [claude, codex] where p.hasWindows {
            var parts: [String] = []
            if let f = p.fiveHour { parts.append("5hr: \(Format.percent(f.usedPercent))") }
            if let w = p.weekly { parts.append("Weekly \(Format.percent(w.usedPercent))") }
            print("  \(p.name)  \(parts.joined(separator: " | "))")
        }
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
    case "on":  print(LoginItem.setEnabled(true) ? "login item: enabled" : "failed to enable")
    case "off": print(LoginItem.setEnabled(false) ? "login item: disabled" : "failed to disable")
    default:    print("login item: \(LoginItem.isEnabled ? "enabled" : "not enabled")")
    }
    exit(0)
}

UsageMeterApp.main()

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
