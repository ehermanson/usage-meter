import Darwin
import Foundation

/// One atomic cache shared by the phone and widget. Readers never combine values
/// from different accounts or source Macs. Switching accounts removes everything.
public struct CompanionCache: Codable, Equatable, Sendable {
    public var accountID: String?
    public var selectedSourceID: UUID?
    public var snapshot: CompanionSnapshot?

    public init(
        accountID: String? = nil, selectedSourceID: UUID? = nil,
        snapshot: CompanionSnapshot? = nil
    ) {
        self.accountID = accountID
        self.selectedSourceID = selectedSourceID
        self.snapshot = snapshot
    }

    public mutating func accept(_ snapshot: CompanionSnapshot, accountID: String) throws {
        _ = try snapshot.validated()
        if self.accountID != accountID {
            self = Self(accountID: accountID)
        }
        if let old = self.snapshot, old.sourceID == snapshot.sourceID,
            old.revision > snapshot.revision
        {
            return
        }
        selectedSourceID = snapshot.sourceID
        self.snapshot = snapshot
    }
}

public enum CompanionCacheFile {
    public static var url: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                CompanionConfiguration.appGroup)?.appendingPathComponent("companion-cache.json")
    }

    public static func load(from url: URL?) -> CompanionCache {
        guard let url, let data = try? Data(contentsOf: url),
            let cache = try? JSONDecoder().decode(CompanionCache.self, from: data),
            cache.snapshot.map({
                (try? $0.validated()) != nil
                    && $0.sourceID == cache.selectedSourceID
            }) ?? true
        else { return CompanionCache() }
        return cache
    }

    public static func save(_ cache: CompanionCache, to url: URL?) throws {
        try withLock(url) { url in
            let current = load(from: url)
            if current.accountID == cache.accountID,
                current.selectedSourceID == cache.selectedSourceID,
                let old = current.snapshot, let next = cache.snapshot,
                old.revision > next.revision
            {
                return
            }
            try write(cache, to: url)
        }
    }

    /// A widget fetch must not undo a source switch, disconnect, or account change
    /// made by the app while its network request was in flight.
    public static func refresh(
        _ snapshot: CompanionSnapshot, accountID: String, at url: URL?
    ) throws -> CompanionCache {
        try withLock(url) { url in
            var current = load(from: url)
            if current.accountID == accountID && current.selectedSourceID == snapshot.sourceID {
                try current.accept(snapshot, accountID: accountID)
                try write(current, to: url)
            }
            return current
        }
    }

    public static func clear(
        ifMatching expected: CompanionCache, at url: URL?
    ) throws -> CompanionCache {
        try withLock(url) { url in
            let current = load(from: url)
            guard current == expected else { return current }
            let empty = CompanionCache()
            try write(empty, to: url)
            return empty
        }
    }

    private static func write(_ cache: CompanionCache, to url: URL) throws {
        try JSONEncoder().encode(cache).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func withLock<T>(_ url: URL?, body: (URL) throws -> T) throws -> T {
        guard let url else { throw CompanionError.notConfigured }
        let descriptor = open(
            url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body(url)
    }
}
