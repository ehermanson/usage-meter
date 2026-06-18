import Foundation

/// Fetches Codex usage by speaking JSON-RPC 2.0 (newline-delimited) to a
/// freshly spawned `codex app-server --listen stdio://` subprocess:
///   1. initialize
///   2. initialized (notification)
///   3. account/rateLimits/read  -> primary (5h) + secondary (weekly)
enum CodexClient {
    static func fetch() async -> ProviderUsage {
        guard let codex = findCodex() else {
            return .failed("Codex", "codex binary not found")
        }
        do {
            let result = try await exchange(codexPath: codex)
            return parse(result)
        } catch {
            return .failed("Codex", error.localizedDescription)
        }
    }

    // MARK: - JSON-RPC exchange

    private static func exchange(codexPath: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let session = CodexRPCSession(codexPath: codexPath, continuation: continuation)
            session.start()
        }
    }

    // MARK: - Parsing

    private static func parse(_ root: [String: Any]) -> ProviderUsage {
        // Shape: { rateLimits: { primary: {...}, secondary: {...} }, ... }
        guard let rl = root["rateLimits"] as? [String: Any]
            ?? (root["rate_limits"] as? [String: Any]) else {
            return .failed("Codex", "No rate-limit data")
        }
        var windows: [UsageWindow] = []
        if let w = window(from: rl["primary"], fallbackLabel: "5h") { windows.append(w) }
        if let w = window(from: rl["secondary"], fallbackLabel: "Weekly") { windows.append(w) }
        if windows.isEmpty {
            return .failed("Codex", "No windows")
        }
        return ProviderUsage(name: "Codex", windows: windows, error: nil)
    }

    private static func window(from raw: Any?, fallbackLabel: String) -> UsageWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let used = num(d["usedPercent"] ?? d["used_percent"]) ?? 0
        let mins = num(d["windowDurationMins"] ?? d["window_minutes"] ?? d["windowMinutes"])
        let label = labelFor(windowMinutes: mins, fallback: fallbackLabel)
        var reset: Date?
        if let epoch = num(d["resetsAt"] ?? d["resets_at"]) {
            reset = Date(timeIntervalSince1970: epoch)
        }
        return UsageWindow(label: label, usedPercent: used, resetAt: reset)
    }

    private static func labelFor(windowMinutes: Double?, fallback: String) -> String {
        guard let m = windowMinutes else { return fallback }
        switch Int(m) {
        case 300: return "5h"
        case 1440: return "Daily"
        case 10080: return "Weekly"
        default:
            if m < 1440 { return "\(Int(m / 60))h" }
            return "\(Int(m / 1440))d"
        }
    }

    private static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    // MARK: - Locate the codex binary

    private static func findCodex() -> String? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to a login-shell PATH lookup.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}

/// Drives one short-lived JSON-RPC conversation with `codex app-server`.
private final class CodexRPCSession {
    private let codexPath: String
    private let continuation: CheckedContinuation<[String: Any], Error>
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private var buffer = Data()
    private var finished = false
    private let lock = NSLock()

    init(codexPath: String, continuation: CheckedContinuation<[String: Any], Error>) {
        self.codexPath = codexPath
        self.continuation = continuation
    }

    func start() {
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Ensure Homebrew paths are visible to the subprocess.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { "\(extra):\($0)" }) ?? extra
        process.environment = env

        // Strong capture of self keeps the session alive for the duration of the
        // exchange; finish() clears the handler to break the cycle.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            self.onData(chunk)
        }

        do {
            try process.run()
        } catch {
            finish(.failure(error))
            return
        }

        // 1. initialize
        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "usage-bar", "version": "1.0.0"],
                         "capabilities": ["experimentalApi": true]]])

        // Watchdog timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(.failure(NSError(domain: "Codex", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out talking to codex app-server"])))
        }
    }

    private func onData(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            handle(msg)
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard let id = (msg["id"] as? NSNumber)?.intValue, msg["method"] == nil else {
            return // notification or request from server — ignore
        }
        switch id {
        case 1: // initialize response -> notify + ask for rate limits
            send(["jsonrpc": "2.0", "method": "initialized"])
            send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"])
        case 2: // rateLimits response
            if let err = msg["error"] as? [String: Any] {
                let m = (err["message"] as? String) ?? "RPC error"
                finish(.failure(NSError(domain: "Codex", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: m])))
            } else if let result = msg["result"] as? [String: Any] {
                finish(.success(result))
            } else {
                finish(.failure(NSError(domain: "Codex", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Empty rate-limit result"])))
            }
        default:
            break
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        inPipe.fileHandleForWriting.write(line)
    }

    private func finish(_ result: Result<[String: Any], Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()

        outPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }

        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
