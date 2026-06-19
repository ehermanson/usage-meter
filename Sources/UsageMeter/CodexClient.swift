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

    /// Exposed for tests. Maps a decoded `account/rateLimits/read` result to usage.
    static func parse(_ root: [String: Any]) -> ProviderUsage {
        // Prefer the per-limit map (one entry per pool); fall back to the single
        // default object. Shape: { rateLimitsByLimitId: { id: {primary, secondary,
        // limitName, planType} }, rateLimits: { ... } }
        let byId =
            root["rateLimitsByLimitId"] as? [String: Any]
            ?? root["rate_limits_by_limit_id"] as? [String: Any]
        let defaultRl =
            root["rateLimits"] as? [String: Any]
            ?? root["rate_limits"] as? [String: Any]

        var sources: [(id: String, dict: [String: Any])] = []
        if let byId, !byId.isEmpty {
            sources = byId.compactMap { key, value in
                (value as? [String: Any]).map { (key, $0) }
            }
            // Show the default "codex" pool first, then the rest alphabetically.
            sources.sort { lhs, rhs in
                if lhs.id == "codex" { return true }
                if rhs.id == "codex" { return false }
                return lhs.id < rhs.id
            }
        } else if let defaultRl {
            sources = [("codex", defaultRl)]
        }

        guard !sources.isEmpty else { return .failed("Codex", "No rate-limit data") }

        let plan = prettyPlan(
            (defaultRl?["planType"] ?? sources.first?.dict["planType"]) as? String)

        var pools: [UsagePool] = []
        for src in sources {
            var windows: [UsageWindow] = []
            if let w = window(from: src.dict["primary"], fallbackLabel: "5h") { windows.append(w) }
            if let w = window(from: src.dict["secondary"], fallbackLabel: "Weekly") {
                windows.append(w)
            }
            if windows.isEmpty { continue }
            let title = poolTitle(limitName: src.dict["limitName"] as? String, limitId: src.id)
            pools.append(UsagePool(title: title, windows: windows))
        }

        // Drop named pools whose windows exactly duplicate an earlier pool
        // (e.g. a per-model limit that mirrors the default) to cut noise.
        var seen = Set<String>()
        let deduped = pools.filter { pool in
            let sig = pool.windows
                .map { "\($0.label):\($0.usedPercent):\($0.resetAt?.timeIntervalSince1970 ?? -1)" }
                .joined(separator: "|")
            return seen.insert(sig).inserted
        }

        if deduped.isEmpty { return .failed("Codex", "No windows", plan: plan) }
        return .ok("Codex", pools: deduped, plan: plan)
    }

    /// The default "codex" pool gets no subheader; named pools show their label.
    private static func poolTitle(limitName: String?, limitId: String) -> String? {
        if let name = limitName, !name.isEmpty { return name }
        return limitId == "codex" ? nil : limitId
    }

    private static func prettyPlan(_ str: String?) -> String? {
        guard let raw = str, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite", "pro_lite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        default: return raw.capitalized
        }
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
        ProcessTools.findExecutable(
            "codex",
            candidates: [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(NSHomeDirectory())/.local/bin/codex",
            ])
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
        send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "clientInfo": ["name": "usage-meter", "version": "1.0.0"],
                "capabilities": ["experimentalApi": true],
            ],
        ])

        // Watchdog timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.finish(
                .failure(
                    NSError(
                        domain: "Codex", code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Timed out talking to codex app-server"
                        ])))
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
            return  // notification or request from server — ignore
        }
        switch id {
        case 1:  // initialize response -> notify + ask for rate limits
            send(["jsonrpc": "2.0", "method": "initialized"])
            send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"])
        case 2:  // rateLimits response
            if let err = msg["error"] as? [String: Any] {
                let m = (err["message"] as? String) ?? "RPC error"
                finish(
                    .failure(
                        NSError(
                            domain: "Codex", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: m])))
            } else if let result = msg["result"] as? [String: Any] {
                finish(.success(result))
            } else {
                finish(
                    .failure(
                        NSError(
                            domain: "Codex", code: -3,
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
        try? inPipe.fileHandleForWriting.close()
        let proc = process
        if proc.isRunning { proc.terminate() }
        // Reap the child off the caller's queue so it can't become a zombie.
        DispatchQueue.global().async { proc.waitUntilExit() }

        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
