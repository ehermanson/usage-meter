import Foundation

// `UsageBar --selftest` fetches both providers from the terminal and prints the
// result, so the data path can be validated without the menu-bar UI.
if CommandLine.arguments.contains("--selftest") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let claude = await ClaudeClient.fetch()
        let codex = await CodexClient.fetch()
        for p in [claude, codex] {
            print("\(p.name):")
            if let err = p.error {
                print("  error: \(err)")
            } else {
                for w in p.windows {
                    let reset = Format.relativeReset(w.resetAt)
                    print(String(format: "  %-8@ %5.1f%%  %@",
                                 w.label as NSString, w.usedPercent, reset as NSString))
                }
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

UsageBarApp.main()
