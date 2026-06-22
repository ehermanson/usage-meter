import Foundation

/// Small helpers for locating CLI tools and running them to completion.
enum ProcessTools {
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    enum ProcessError: LocalizedError {
        case timedOut
        var errorDescription: String? {
            switch self {
            case .timedOut: return "Timed out"
            }
        }
    }

    /// Run an executable to completion, capturing stdout/stderr, with a timeout.
    static func run(
        executable: String,
        arguments: [String],
        cwd: URL? = nil,
        extraEnv: [String: String] = [:],
        timeout: TimeInterval = 40
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Result, Error>) in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                if let cwd { proc.currentDirectoryURL = cwd }

                var env = ProcessInfo.processInfo.environment
                let extra = "/opt/homebrew/bin:/usr/local/bin"
                env["PATH"] = (env["PATH"].map { "\(extra):\($0)" }) ?? extra
                for (k, v) in extraEnv { env[k] = v }
                proc.environment = env

                let outPipe = Pipe(), errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                // Drain both pipes concurrently to avoid buffer deadlock.
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try proc.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }

                let timedOut = TimeoutFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if proc.isRunning {
                        timedOut.set()
                        proc.terminate()
                    }
                }

                proc.waitUntilExit()
                group.wait()

                if timedOut.value {
                    cont.resume(throwing: ProcessError.timedOut)
                } else {
                    cont.resume(
                        returning: Result(
                            stdout: String(data: outData, encoding: .utf8) ?? "",
                            stderr: String(data: errData, encoding: .utf8) ?? "",
                            exitCode: proc.terminationStatus
                        ))
                }
            }
        }
    }

    /// Locate `node`, including version-managed installs only reachable via the
    /// user's login-shell PATH (the menu-bar app inherits a minimal PATH).
    static func findNode() -> String? {
        let home = NSHomeDirectory()
        return findExecutable(
            "node",
            candidates: [
                "/opt/homebrew/bin/node",
                "/usr/local/bin/node",
                "\(home)/.local/bin/node",
                "\(home)/.volta/bin/node",  // Volta
                "\(home)/.asdf/shims/node",  // asdf
                "/opt/local/bin/node",  // MacPorts
            ])
    }

    /// Locate the user's Claude Code native binary, which the Agent SDK drives
    /// via `pathToClaudeCodeExecutable`.
    static func findClaude() -> String? {
        findExecutable(
            "claude",
            candidates: [
                "\(NSHomeDirectory())/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(NSHomeDirectory())/.claude/local/claude",
            ])
    }

    static func findExecutable(_ name: String, candidates: [String]) -> String? {
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // A Finder-launched app inherits a minimal PATH, so fall back to the
        // user's login shell. Try a plain login shell first (fast); then an
        // interactive one, which sources the rc files (e.g. ~/.zshrc) where
        // version managers — nvm, fnm, Volta, asdf — put node/claude on PATH.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        for flags in [["-l", "-c"], ["-i", "-l", "-c"]] {
            if let path = shellLookup(shell: shell, flags: flags, name: name) {
                return path
            }
        }
        return nil
    }

    private static func shellLookup(shell: String, flags: [String], name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = flags + ["command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice  // never block on stdin
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        // An interactive shell may print rc banners, so scan lines (newest last)
        // for one that resolves to a real executable.
        for line in text.split(separator: "\n").reversed() {
            let path = line.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}

/// Thread-safe one-shot boolean.
private final class TimeoutFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
