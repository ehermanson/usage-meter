import Darwin
import Foundation

/// What one scan found: every record from every tracked file (not yet
/// deduped — that needs all files at once, and happens in aggregation), plus
/// which providers have logs on this Mac at all.
struct ActivityScanResult: Sendable {
    let records: [UsageRecord]
    /// Bumped whenever `records` is rebuilt. Two results from one scanner
    /// with the same generation hold the same records, so whatever a caller
    /// derived from the first (the deduped set, say) still holds for the
    /// second, however the scans interleaved.
    let generation: Int
    /// Providers with at least one log file, of any age.
    let detectedProviders: Set<String>
    let stats: ActivityScanStats
}

struct ActivityScanStats: Sendable {
    /// Log files within the age cutoff.
    let files: Int
    /// Files that had new bytes this pass.
    let filesRead: Int
    let bytesRead: Int64
    let duration: TimeInterval
}

/// Reads the providers' session logs incrementally, off the main actor.
///
/// Cold, this is a couple of gigabytes of JSONL; warm, almost nothing has
/// changed. So each file's progress is kept between scans — how far it has
/// been read, and the parser holding whatever state its format needs — and a
/// refresh reads only bytes appended since. A file that shrank, was replaced
/// (a different inode at the same path), or was rewritten in place (its
/// first bytes changed) is read again from the start; one that vanished is
/// forgotten.
///
/// Only complete lines are consumed. A line still being written stays unread
/// past the saved offset and is picked up whole next time, so a half-written
/// JSON object is never seen.
///
/// Memory stays at one fixed-size buffer however long a line runs. Codex
/// inlines images and tool output, so its lines reach 15 MB, but none that
/// long has held a marker. A line longer than the buffer is streamed through
/// it and only searched, and read whole — into memory freed straight after —
/// only if it turns out to matter.
///
/// Scans run on a private serial queue rather than Swift's cooperative pool.
/// A cold one spends seconds blocked in `read`, and the pool has only a
/// thread per core: holding one that long starves unrelated async work. The
/// queue's utility QoS also keeps a cold scan from competing with anything
/// the user is looking at, whoever asked for it.
///
/// Isolation: `queue` owns every piece of mutable state — the file table,
/// the cached records, the parsers, the decoder, and the read buffer. The
/// only way in is `scan`, which runs its whole body there, one scan at a
/// time; everything else is immutable after `init`. That discipline is what
/// the `@unchecked Sendable` rests on, so keep new state behind it.
final class ActivityScanner: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
    }

    private struct FileState {
        let source: Int
        let identity: FileIdentity
        /// Size and mtime as of the last read that got to the end of the
        /// file; a size of -1 until one has.
        var size: Int64
        var modified: timespec
        /// Byte offset just past the last complete line consumed.
        var offset: Int64
        /// The file's first bytes (up to `headLength`) as they were before
        /// it was first read. An appended-to log keeps them; one rewritten
        /// in place — same inode, as big or bigger — almost never does, and
        /// reading on from the old offset would stitch new content onto old
        /// records. Shorter than `headLength` if the file was, and extended
        /// as it grows.
        var head: Data
        let parser: ActivityLogParser
    }

    private let queue = DispatchQueue(label: "UsageMeter.ActivityScanner", qos: .utility)
    private let sources: [any ActivityLogSource]
    private let markers: [MarkerSet]
    private let maxAge: TimeInterval
    private var files: [String: FileState] = [:]
    /// The last result's records, reused while no file has changed — a warm
    /// refresh then costs little more than the directory walk and the stats.
    private var cachedRecords: [UsageRecord]?
    private var generation = 0
    private let decoder = JSONDecoder()
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private let maxLineLength: Int

    /// Big enough that a whole day's log is a handful of reads, small enough
    /// to be a non-event in memory. Never grows: see the type's doc comment.
    static let defaultChunkSize = 4 << 20

    /// A line with a marker longer than this is skipped rather than read
    /// into memory whole. The longest on the machine this was written on is
    /// 215 KB; this is far past any real one, and only bounds what a corrupt
    /// file could make a scan hold.
    static let defaultMaxLineLength = 64 << 20

    /// Files untouched for longer than this can't hold anything a range
    /// shows. It's the widest range (90 days) plus a day: "90d" starts at
    /// local midnight 89 days back, which can be up to 90 days and an hour
    /// ago across a DST change.
    static let defaultMaxAge: TimeInterval = 91 * 24 * 3600

    /// How much of each file's start is kept to spot an in-place rewrite:
    /// past the session id both tools put in a log's first line, and small
    /// enough that a few thousand tracked files hold a megabyte or so. A
    /// rewrite that leaves these bytes as they were goes unnoticed; catching
    /// that would mean rereading everything already read.
    static let headLength = 256

    init(
        sources: [any ActivityLogSource] = ActivitySources.all,
        maxAge: TimeInterval = ActivityScanner.defaultMaxAge,
        chunkSize: Int = ActivityScanner.defaultChunkSize,
        maxLineLength: Int = ActivityScanner.defaultMaxLineLength
    ) {
        let markers = sources.map { MarkerSet($0.markers) }
        self.sources = sources
        self.markers = markers
        self.maxAge = maxAge
        self.maxLineLength = maxLineLength
        // Room for a marker's worth of overlap when a long line is searched
        // a read at a time, and more than that to read each time.
        self.capacity = max(16, chunkSize, 2 * (markers.map(\.longest).max() ?? 0))
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        // A running scan's block holds `self`, so this can't overlap one.
        buffer.deallocate()
    }

    func scan(now: Date = .now) async -> ActivityScanResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.scanOnQueue(now: now)) }
        }
    }

    private func scanOnQueue(now: Date) -> ActivityScanResult {
        dispatchPrecondition(condition: .onQueue(queue))
        let started = Date.now
        var seen = Set<String>()
        var detected = Set<String>()
        var changed = false
        var filesRead = 0
        var bytesRead: Int64 = 0
        let cutoff = now.addingTimeInterval(-maxAge).timeIntervalSince1970

        for (index, source) in sources.enumerated() {
            let paths = source.logFiles()
            if !paths.isEmpty { detected.insert(source.name) }
            for url in paths {
                let path = url.path
                var info = stat()
                guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let modified = info.st_mtimespec
                guard Double(modified.tv_sec) >= cutoff else { continue }
                guard seen.insert(path).inserted else { continue }

                let identity = FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
                var known = files[path]
                if let state = known {
                    if state.identity != identity || info.st_size < state.size
                        || info.st_size < state.offset
                    {
                        known = nil  // replaced or truncated
                    } else if info.st_size == state.size, modified == state.modified {
                        continue
                    }
                }

                // Only new files and ones whose size or time moved get this
                // far, so a warm scan opens just those, reading each head once.
                let fd = open(path, O_RDONLY | O_CLOEXEC)
                defer { if fd >= 0 { close(fd) } }
                // Taken before the read, so if the file is rewritten between
                // the two, the head is the old one and the next scan starts
                // over — never the reverse, which would miss it.
                let head = fd >= 0 ? Self.head(of: fd) : nil
                var state: FileState
                if var kept = known, head.map({ $0.starts(with: kept.head) }) ?? true {
                    // Grown or touched. A head that can't be read yet says
                    // nothing either way; the read below will fail the same
                    // way and be retried.
                    if let head, head.count > kept.head.count { kept.head = head }
                    state = kept
                } else {
                    // New, replaced, truncated, or rewritten in place: start
                    // over with a fresh parser. That drops whatever the old
                    // one held, so the records change even if nothing is read.
                    state = FileState(
                        source: index, identity: identity, size: -1, modified: modified,
                        offset: 0, head: head ?? Data(), parser: source.makeParser(for: url))
                    changed = true
                }
                let before = state.offset
                let result =
                    fd >= 0
                    ? read(fd, from: state.offset, into: state.parser, markers[index])
                    : (offset: state.offset, complete: false)
                state.offset = result.offset
                // The file's size and time are taken only once a read gets
                // to its end. After a failure they stay as they were (none,
                // for a new file), so it doesn't pass for unchanged next scan
                // and is tried again: a transcript that couldn't be opened —
                // root-owned from a `sudo` run, say — is read once it can be,
                // though fixing its permissions changes neither.
                if result.complete {
                    state.size = info.st_size
                    state.modified = modified
                }
                files[path] = state
                filesRead += 1
                bytesRead += max(0, state.offset - before)
                // Only consumed lines reach the parser, so a file that was
                // tried and yielded nothing — unreadable, or with only a
                // partial line added — leaves the records as they were.
                if state.offset != before { changed = true }
            }
        }

        // Vanished, or aged past the cutoff.
        let gone = files.keys.filter { !seen.contains($0) }
        if !gone.isEmpty {
            for path in gone { files[path] = nil }
            changed = true
        }

        if changed || cachedRecords == nil {
            // Source order, then path order, so ties in dedupe resolve the
            // same way every scan.
            cachedRecords = files.sorted {
                ($0.value.source, $0.key) < ($1.value.source, $1.key)
            }.flatMap { $0.value.parser.records }
            generation += 1
        }

        return ActivityScanResult(
            records: cachedRecords ?? [], generation: generation, detectedProviders: detected,
            stats: ActivityScanStats(
                files: files.count, filesRead: filesRead, bytesRead: bytesRead,
                duration: Date.now.timeIntervalSince(started)))
    }

    /// Up to `headLength` bytes from the start of the file (fewer if it's
    /// shorter), or nil if they can't be read.
    private static func head(of fd: Int32) -> Data? {
        var data = Data(count: headLength)
        var done = 0
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            while done < headLength {
                let n = pread(fd, base + done, headLength - done, off_t(done))
                if n < 0, errno == EINTR { continue }
                guard n >= 0 else { return false }
                if n == 0 { break }
                done += n
            }
            return true
        }
        guard complete else { return nil }
        data.count = done
        return data
    }

    /// Reads `fd` from `offset` in large chunks and feeds each complete line
    /// that contains a marker to `parser`. Returns the offset just past the
    /// last complete line, and whether the read got to the end of the file:
    /// false if a read failed, though lines before the failure are consumed
    /// all the same.
    ///
    /// The marker search runs over the whole chunk rather than line by line:
    /// the lines that matter are a small fraction of the bytes, so finding a
    /// hit first and only then its line's bounds skips splitting everything
    /// else.
    private func read(
        _ fd: Int32, from offset: Int64, into parser: ActivityLogParser, _ markers: MarkerSet
    ) -> (offset: Int64, complete: Bool) {
        guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return (offset, false) }

        var consumed = offset
        var carried = 0  // bytes of a partial line kept at the buffer's start
        while true {
            if carried == capacity {
                // One line fills the whole buffer.
                switch passLongLine(fd, from: consumed, into: parser, markers) {
                case .passed(let end):
                    consumed = end
                    carried = 0
                    guard lseek(fd, off_t(end), SEEK_SET) == off_t(end) else {
                        return (consumed, false)
                    }
                    continue
                case .unfinished:
                    return (consumed, true)
                case .failed:
                    return (consumed, false)
                }
            }
            let n = Darwin.read(fd, buffer + carried, capacity - carried)
            if n < 0 {
                if errno == EINTR { continue }
                return (consumed, false)
            }
            if n == 0 { return (consumed, true) }
            let filled = carried + n
            let bytes = UnsafePointer(buffer.assumingMemoryBound(to: UInt8.self))
            guard let lastNewline = Self.lastNewline(bytes, from: 0, before: filled) else {
                carried = filled  // no line ends in the buffer yet
                continue
            }
            let end = lastNewline + 1
            var cursor = 0
            while let hit = markers.firstMatch(bytes, from: cursor, to: end) {
                let lineStart =
                    (Self.lastNewline(bytes, from: cursor, before: hit) ?? cursor - 1) + 1
                let lineEnd = Self.nextNewline(bytes, from: hit, to: end) ?? (end - 1)
                parser.consume(
                    Data(bytes: bytes + lineStart, count: lineEnd - lineStart), decoder: decoder)
                cursor = lineEnd + 1
            }
            consumed += Int64(end)
            carried = filled - end
            if carried > 0 { memmove(buffer, buffer + end, carried) }
        }
    }

    private enum LongLine {
        /// Read through its newline; the next line starts at `end`.
        case passed(end: Int64)
        /// The file ends before the line does: it's still being written.
        case unfinished
        case failed
    }

    /// Carries on through a line longer than the buffer, which holds its
    /// first `capacity` bytes (from file offset `start`, with `fd` just past
    /// them), without growing the buffer to fit it.
    ///
    /// The rest streams through the buffer a read at a time, searched for a
    /// marker and otherwise dropped, so a long line that doesn't matter costs
    /// no memory. One that holds a marker is read again whole, into memory
    /// of its own that's freed once it's parsed.
    private func passLongLine(
        _ fd: Int32, from start: Int64, into parser: ActivityLogParser, _ markers: MarkerSet
    ) -> LongLine {
        let bytes = UnsafePointer(buffer.assumingMemoryBound(to: UInt8.self))
        var hasMarker = markers.firstMatch(bytes, from: 0, to: capacity) != nil
        var length = Int64(capacity)
        // The end of each read is kept ahead of the next, so a marker split
        // across the two is still found whole.
        let overlap = max(0, markers.longest - 1)
        memmove(buffer, buffer + capacity - overlap, overlap)
        while true {
            let n = Darwin.read(fd, buffer + overlap, capacity - overlap)
            if n < 0 {
                if errno == EINTR { continue }
                return .failed
            }
            if n == 0 { return .unfinished }
            let filled = overlap + n
            let newline = Self.nextNewline(bytes, from: overlap, to: filled)
            let lineEnd = newline ?? filled
            if !hasMarker { hasMarker = markers.firstMatch(bytes, from: 0, to: lineEnd) != nil }
            length += Int64(lineEnd - overlap)
            if newline != nil { break }
            memmove(buffer, buffer + filled - overlap, overlap)
        }
        if hasMarker, length <= maxLineLength {
            guard let line = Self.bytes(fd, count: Int(length), at: start) else { return .failed }
            parser.consume(line, decoder: decoder)
        }
        return .passed(end: start + length + 1)
    }

    /// Exactly `count` bytes at `offset`, or nil if they can't all be read.
    private static func bytes(_ fd: Int32, count: Int, at offset: Int64) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return count == 0 }
            var done = 0
            while done < count {
                let n = pread(fd, base + done, count - done, off_t(offset) + off_t(done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return false }
                done += n
            }
            return true
        }
        return complete ? data : nil
    }

    private static func nextNewline(_ bytes: UnsafePointer<UInt8>, from: Int, to end: Int) -> Int? {
        guard from < end, let found = memchr(bytes + from, 0x0A, end - from) else { return nil }
        return UnsafeRawPointer(bytes).distance(to: UnsafeRawPointer(found))
    }

    /// The last `\n` in `[from, before)`, 16 bytes at a time.
    static func lastNewline(_ bytes: UnsafePointer<UInt8>, from: Int, before: Int) -> Int? {
        let newline = SIMD16<UInt8>(repeating: 0x0A)
        var i = before
        while i - 16 >= from {
            let block = UnsafeRawPointer(bytes).loadUnaligned(
                fromByteOffset: i - 16, as: SIMD16<UInt8>.self)
            let hits = block .== newline
            if any(hits) {
                for lane in stride(from: 15, through: 0, by: -1) where hits[lane] {
                    return i - 16 + lane
                }
            }
            i -= 16
        }
        while i > from {
            i -= 1
            if bytes[i] == 0x0A { return i }
        }
        return nil
    }
}

/// Finds the earliest occurrence of any of a few byte strings.
///
/// `memmem` manages about half a gigabyte a second here, which for four
/// markers over Codex's logs alone is seconds. This checks two bytes of each
/// marker across 16 candidate positions at once (the "SIMD-friendly
/// substring search" trick) and only compares whole markers where both hit.
/// The two bytes are taken from inside the marker, not its quotes — nearly
/// every JSON key starts and ends with a quote.
struct MarkerSet: Sendable {
    private let needles: [[UInt8]]
    private let firstOffsets: [Int]
    private let secondOffsets: [Int]
    private let firstBytes: [SIMD16<UInt8>]
    private let secondBytes: [SIMD16<UInt8>]
    /// The furthest any vector load reaches past its candidate position.
    private let reach: Int
    /// The longest marker's length in bytes.
    let longest: Int

    init(_ markers: [String]) {
        needles = markers.map { Array($0.utf8) }.filter { !$0.isEmpty }
        firstOffsets = needles.map { $0.count >= 4 ? 1 : 0 }
        secondOffsets = needles.map { $0.count >= 4 ? $0.count - 2 : $0.count - 1 }
        firstBytes = zip(needles, firstOffsets).map { SIMD16(repeating: $0[$1]) }
        secondBytes = zip(needles, secondOffsets).map { SIMD16(repeating: $0[$1]) }
        longest = needles.map(\.count).max() ?? 0
        reach = longest + 16
    }

    /// Start of the earliest match beginning in `[from, end)` and ending by `end`.
    func firstMatch(_ bytes: UnsafePointer<UInt8>, from: Int, to end: Int) -> Int? {
        guard !needles.isEmpty else { return nil }
        let raw = UnsafeRawPointer(bytes)
        var i = from
        while i + reach <= end {
            var candidates = SIMDMask<SIMD16<Int8>>(repeating: false)
            for k in 0..<needles.count {
                let a = raw.loadUnaligned(
                    fromByteOffset: i + firstOffsets[k], as: SIMD16<UInt8>.self)
                let b = raw.loadUnaligned(
                    fromByteOffset: i + secondOffsets[k], as: SIMD16<UInt8>.self)
                candidates .|= (a .== firstBytes[k]) .& (b .== secondBytes[k])
            }
            if any(candidates) {
                for lane in 0..<16 where candidates[lane] {
                    if matches(bytes, at: i + lane, end: end) { return i + lane }
                }
            }
            i += 16
        }
        while i < end {
            if matches(bytes, at: i, end: end) { return i }
            i += 1
        }
        return nil
    }

    private func matches(_ bytes: UnsafePointer<UInt8>, at position: Int, end: Int) -> Bool {
        for needle in needles where position + needle.count <= end {
            let equal = needle.withUnsafeBufferPointer {
                memcmp(bytes + position, $0.baseAddress!, needle.count) == 0
            }
            if equal { return true }
        }
        return false
    }
}

private func == (lhs: timespec, rhs: timespec) -> Bool {
    lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
}
