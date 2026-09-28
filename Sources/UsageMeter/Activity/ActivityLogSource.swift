import Foundation

/// A provider whose local session logs feed the Tokens and Cost tabs.
///
/// To add one: say where its files live and which byte markers flag a line
/// worth decoding, and supply a parser. The scanner handles enumeration,
/// incremental reads, and the age cutoff; the aggregator handles dedupe,
/// pricing, and bucketing — so a new provider is one new parser.
protocol ActivityLogSource: Sendable {
    /// Must match the provider's name in `UsageStore`, so the two tabs agree
    /// on labels, accents, and logos.
    var name: String { get }
    /// Byte strings of which a line must contain at least one to be decoded.
    /// Session logs are mostly message content; skipping the rest without
    /// JSON-decoding it is most of what keeps a cold scan fast.
    var markers: [String] { get }
    /// Every log file on disk, of any age (the scanner applies the cutoff).
    /// An empty result means the tool isn't used on this Mac.
    func logFiles() -> [URL]
    /// A fresh parser for one file. It lives as long as the file is tracked,
    /// so state a format needs across lines survives the file growing.
    func makeParser(for file: URL) -> ActivityLogParser
}

/// Turns one file's matching lines, fed in order, into usage records.
protocol ActivityLogParser: AnyObject {
    func consume(_ line: Data, decoder: JSONDecoder)
    /// Everything read from the file so far.
    var records: [UsageRecord] { get }
}

enum ActivitySources {
    /// Registry order, which is also the order providers appear in.
    static let all: [any ActivityLogSource] = all(until: nil)

    /// The registry with every log line stamped after `cutoff` ignored, as
    /// if not yet written — the logs as they stood then. The CLI's `--now`
    /// uses it so a run can be repeated exactly while the logs keep growing.
    static func all(until cutoff: Date?) -> [any ActivityLogSource] {
        [ClaudeLogSource(until: cutoff), CodexLogSource(until: cutoff)]
    }

    /// Recursively lists `*.jsonl` under each directory that exists.
    ///
    /// A root that's a symlink is followed: `projects` or `sessions` moved to
    /// another volume and linked back is still found, where enumerating the
    /// link itself would list nothing. Links further down aren't followed,
    /// so a loop can't trap the walk. Roots that resolve to the same
    /// directory are walked once.
    static func jsonlFiles(under roots: [URL]) -> [URL] {
        var files: [URL] = []
        var walked = Set<String>()
        let fm = FileManager.default
        for root in roots.map(resolved) {
            var isDir: ObjCBool = false
            guard walked.insert(root.path).inserted,
                fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
                let walker = fm.enumerator(
                    at: root, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                files.append(url)
            }
        }
        return files
    }

    /// Expands `~` and resolves symlinks, so two spellings of one directory
    /// dedupe to a single root instead of double counting its files.
    static func resolved(_ path: String) -> URL {
        resolved(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

/// Claude Code: `<config dir>/projects/**/*.jsonl`, subagent transcripts
/// included (they carry their parent's sessionId).
struct ClaudeLogSource: ActivityLogSource {
    let name = "Claude"
    let markers = ["\"usage\""]
    /// Lines stamped after this are ignored; see `ActivitySources.all(until:)`.
    var until: Date?

    /// Config dirs in precedence order, deduped, existing only: the user's
    /// explicit pick in Settings, then `CLAUDE_CONFIG_DIR`, then the dir the
    /// Limits tab's helper last settled on, then the two default homes. All
    /// of them, not just the first, since a user who switches config dirs
    /// has history in each.
    ///
    /// The helper's dir is what keeps the tabs agreeing: the helper also
    /// looks in a login `/bin/sh`'s environment (so ~/.profile), which an app
    /// started from the Dock or at login never inherits, so a
    /// `CLAUDE_CONFIG_DIR` exported only there is found by Limits and would
    /// otherwise be missed here. That shell doesn't read zsh's startup files,
    /// so an export only in ~/.zshrc is missed by both tabs alike; the folder
    /// picker covers that.
    static func configDirs(
        override: String? = UserDefaults.standard.string(forKey: "claudeConfigDir"),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        detected: String? = UserDefaults.standard.string(
            forKey: ClaudeClient.detectedConfigDirKey),
        home: String = NSHomeDirectory()
    ) -> [URL] {
        var candidates: [String] = []
        if let override, !override.isEmpty { candidates.append(override) }
        if let env = environment["CLAUDE_CONFIG_DIR"] { candidates += entries(of: env) }
        if let detected, !detected.isEmpty { candidates.append(detected) }
        candidates += ["\(home)/.claude", "\(home)/.config/claude"]
        var seen = Set<String>()
        var dirs: [URL] = []
        for candidate in candidates {
            let url = ActivitySources.resolved(candidate)
            guard isDirectory(url), seen.insert(url.path).inserted else { continue }
            dirs.append(url)
        }
        return dirs
    }

    /// `CLAUDE_CONFIG_DIR`'s directories. Claude Code reads it as one path;
    /// log tools like ccusage also accept a comma-separated list, so one that
    /// isn't a directory is split on commas. Checking the whole value first
    /// keeps a path with a comma in its name in one piece.
    static func entries(of value: String) -> [String] {
        // An empty path would resolve to the working directory.
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        if isDirectory(ActivitySources.resolved(value)) { return [value] }
        return value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    func logFiles() -> [URL] {
        ActivitySources.jsonlFiles(
            under: Self.configDirs().map { $0.appendingPathComponent("projects") })
    }

    func makeParser(for file: URL) -> ActivityLogParser {
        ClaudeLogParser(fallbackSessionId: Self.sessionId(forFile: file), until: until)
    }

    /// The session a file belongs to when its lines don't say: the transcript's
    /// own UUID name, or for `<session>/subagents/agent-*.jsonl`, the parent's.
    static func sessionId(forFile file: URL) -> String {
        let parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            return parent.deletingLastPathComponent().lastPathComponent
        }
        return file.deletingPathExtension().lastPathComponent
    }
}

/// Codex: `$CODEX_HOME` (or `~/.codex`), live sessions under
/// `sessions/YYYY/MM/DD/` plus `archived_sessions/`.
struct CodexLogSource: ActivityLogSource {
    let name = "Codex"
    /// Lines stamped after this are ignored; see `ActivitySources.all(until:)`.
    var until: Date?
    /// Quoted, so they match only a JSON string token — the `type` values —
    /// and not the words in prose or escaped inside a tool's output.
    let markers = [
        "\"token_count\"", "\"token_usage_record\"", "\"turn_context\"", "\"session_meta\"",
    ]

    static func home(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return ActivitySources.resolved(dir)
        }
        return ActivitySources.resolved("\(home)/.codex")
    }

    func logFiles() -> [URL] {
        let home = Self.home()
        return ActivitySources.jsonlFiles(under: [
            home.appendingPathComponent("sessions"),
            home.appendingPathComponent("archived_sessions"),
        ])
    }

    func makeParser(for file: URL) -> ActivityLogParser {
        CodexLogParser(fallbackSessionId: Self.sessionId(forFile: file), until: until)
    }

    /// The UUID at the end of `rollout-<timestamp>-<uuid>.jsonl`, used only if
    /// the file has no session_meta line.
    static func sessionId(forFile file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        return stem.count >= 36 ? String(stem.suffix(36)) : stem
    }
}

/// Timestamp parsing on the scan's hot path. `ISO8601DateFormatter` costs
/// microseconds a call, which across ~100k log lines is most of a second;
/// both tools write the same fixed UTC shape, so that shape is read directly
/// and anything else falls back to the formatter.
enum ActivityTime {
    static func parse(_ string: String) -> Date? {
        fastParse(string) ?? Parse.isoDate(string)
    }

    /// `YYYY-MM-DDTHH:MM:SS[.fraction]` followed by `Z` or `±HH:MM`.
    static func fastParse(_ string: String) -> Date? {
        var string = string
        return string.withUTF8 { parse(bytes: $0) }
    }

    private static func parse(bytes b: UnsafeBufferPointer<UInt8>) -> Date? {
        guard b.count >= 20 else { return nil }
        func digits(_ at: Int, _ count: Int) -> Int? {
            var value = 0
            for i in at..<(at + count) {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                value = value * 10 + d
            }
            return value
        }
        guard b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-"),
            b[10] == UInt8(ascii: "T") || b[10] == UInt8(ascii: " "),
            b[13] == UInt8(ascii: ":"), b[16] == UInt8(ascii: ":"),
            let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
            let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            // Whole digits over a power of ten, rather than a running sum of
            // tenths, so ".784" lands on the same Double the formatter gives.
            var numerator = 0
            var denominator = 1
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                if denominator < 1_000_000_000 {
                    numerator = numerator * 10 + Int(b[i] - 48)
                    denominator *= 10
                }
                i += 1
            }
            fraction = Double(numerator) / Double(denominator)
        }
        guard i < b.count else { return nil }
        var offset = 0
        switch b[i] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            guard i + 1 == b.count else { return nil }
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            guard i + 6 == b.count, b[i + 3] == UInt8(ascii: ":"),
                let oh = digits(i + 1, 2), let om = digits(i + 4, 2)
            else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == UInt8(ascii: "-") ? -1 : 1)
        default:
            return nil
        }

        // Days since the Unix epoch for a proleptic Gregorian date (Howard
        // Hinnant's days_from_civil), so no Calendar is involved.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }
}
