import BackgroundTasks
import CloudKit
import CompanionKit
import Observation
import WidgetKit

@MainActor
@Observable
final class CompanionStore {
    static let shared = CompanionStore()
    private(set) var cache = CompanionCacheFile.load(from: CompanionCacheFile.url)
    private(set) var sources: [CompanionSnapshot] = []
    private(set) var isRefreshing = false
    var message: String?
    private(set) var subscriptionMessage: String?
    private(set) var accountVerified = false
    var snapshot: CompanionSnapshot? { accountVerified ? cache.snapshot : nil }

    @ObservationIgnored private var cloud: CloudSnapshotService?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let demo: Bool

    init() {
        demo = ProcessInfo.processInfo.arguments.contains("--companion-demo")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--companion-reset-cache") {
            cache = CompanionCache()
            try? CompanionCacheFile.save(cache, to: CompanionCacheFile.url)
        }
        #endif
        observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.verifyAccountNotification() }
        }
        if demo {
            cache = CompanionCache(
                accountID: "preview", selectedSourceID: Self.demoSnapshot.sourceID,
                snapshot: Self.demoSnapshot)
            accountVerified = true
        }
    }

    private func verifyAccountNotification() async {
        guard !demo else { return }
        epoch += 1
        accountVerified = false
        // Hide cached data immediately, but preserve the selected Mac until
        // verification establishes whether this is actually a different account.
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        await refresh()
    }

    @discardableResult
    func refresh(discoverSources: Bool = false) async -> Bool {
        guard !demo, !isRefreshing else { return false }
        cache = CompanionCacheFile.load(from: CompanionCacheFile.url)
        isRefreshing = true
        let generation = epoch
        defer { isRefreshing = false }
        if cloud == nil { cloud = CloudSnapshotService() }
        guard let cloud else { return false }
        do {
            let identity = try await cloud.accountID()
            guard generation == epoch, !Task.isCancelled else { return false }
            if cache.accountID != identity {
                cache = CompanionCache(accountID: identity)
                sources = []
                try persist()
            }
            accountVerified = true
            if let selected = cache.selectedSourceID, !discoverSources {
                let fresh = try await cloud.fetch(selected)
                guard generation == epoch, !Task.isCancelled else { return false }
                cache = try CompanionCacheFile.refresh(
                    fresh, accountID: identity, at: CompanionCacheFile.url)
                WidgetCenter.shared.reloadAllTimelines()
            } else {
                let found = try await cloud.discover()
                guard generation == epoch, !Task.isCancelled else { return false }
                sources = found
                // Discovery does not silently connect to the first Mac.
            }
            message = nil
            if cache.selectedSourceID != nil {
                do {
                    try await cloud.subscribe()
                    guard generation == epoch, !Task.isCancelled else { return false }
                    subscriptionMessage = nil
                } catch {
                    guard generation == epoch, !Task.isCancelled else { return false }
                    subscriptionMessage =
                        "Background sync isn't available yet. Open the app or pull to refresh."
                }
            }
            return true
        } catch {
            guard generation == epoch, !Task.isCancelled else { return false }
            if (error as? CompanionError) == .noAccount
                || (error as? CKError)?.code == .notAuthenticated
            {
                clearForAccountChange()
            } else if let error = error as? CompanionError, case .sourceNotFound = error {
                cache =
                    (try? CompanionCacheFile.clear(
                        ifMatching: cache, at: CompanionCacheFile.url)) ?? CompanionCache()
                sources = []
                WidgetCenter.shared.reloadAllTimelines()
            }
            message = Self.friendlyMessage(error)
            return false
        }
    }

    func connect(_ url: URL) async {
        guard !demo else { return }
        var generation = epoch
        do {
            let sourceID = try CompanionLink.sourceID(from: url)
            // A scanned ID is untrusted until fetched from our private database.
            epoch += 1
            generation = epoch
            if cloud == nil { cloud = CloudSnapshotService() }
            guard let cloud else { return }
            let identity = try await cloud.accountID()
            let snapshot = try await cloud.fetch(sourceID)
            guard generation == epoch, !Task.isCancelled else { return }
            try cache.accept(snapshot, accountID: identity)
            accountVerified = true
            try persist()
            message = nil
            #if DEBUG
            print("Companion connected; received \(snapshot.providers.count) provider summaries.")
            fflush(stdout)
            #endif
            do {
                try await cloud.subscribe()
                guard generation == epoch, !Task.isCancelled else { return }
                subscriptionMessage = nil
            } catch {
                guard generation == epoch, !Task.isCancelled else { return }
                subscriptionMessage = "Open the app or pull to refresh to update your readings."
            }
        } catch {
            guard generation == epoch, !Task.isCancelled else { return }
            if (error as? CompanionError) == .noAccount
                || (error as? CKError)?.code == .notAuthenticated
            {
                clearForAccountChange()
            }
            message = Self.friendlyMessage(error)
        }
    }

    func disconnect() {
        epoch += 1
        cache = CompanionCache(accountID: cache.accountID)
        sources = []
        message = nil
        subscriptionMessage = nil
        try? persist()
    }

    private func clearForAccountChange() {
        epoch += 1
        cache = CompanionCache()
        sources = []
        accountVerified = false
        subscriptionMessage = nil
        try? persist()
        message = "Your iCloud account changed. Connect your Mac again."
    }

    private func persist() throws {
        guard !demo else { return }
        try CompanionCacheFile.save(cache, to: CompanionCacheFile.url)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func friendlyMessage(_ error: Error) -> String {
        if error is CompanionError { return error.localizedDescription }
        if let error = error as? CKError {
            switch error.code {
            case .notAuthenticated: return CompanionError.noAccount.localizedDescription
            case .networkUnavailable, .networkFailure:
                return
                    "You're offline. Your last saved reading will appear once your iCloud account is verified."
            case .quotaExceeded:
                return "Your iCloud storage is full. Free some space and try again."
            case .badContainer, .missingEntitlement, .permissionFailure:
                return
                    "iCloud sync isn't configured for this build. Check its signing and CloudKit container."
            default: break
            }
        }
        return "Couldn't sync with iCloud. Check your connection and try again."
    }

    static let demoActivity = CompanionActivity(
        capturedAt: .now, timeZoneIdentifier: TimeZone.current.identifier,
        ranges: CompanionRange.allCases.map { range in
            let count = range == .day ? 25 : range == .week ? 7 : range == .month ? 30 : 90
            let step: TimeInterval = range == .day ? 3600 : 86400
            let dates = (0..<count).map {
                Date.now.addingTimeInterval(Double($0 - count + 1) * step)
            }
            let providers = ["Claude", "Codex"].enumerated().map { index, name in
                let tokens = (0..<count).map { i in
                    (100_000 + ((i * 137 + 37) % 11) * 210_000) / (index + 1)
                }
                let costs = tokens.map { Double($0) * (index == 0 ? 0.000008 : 0.000004) }
                return CompanionProviderActivity(
                    name: name, tokens: tokens.reduce(0, +),
                    cost: costs.reduce(0, +), unpricedTokens: 0,
                    sessions: count * (index == 0 ? 4 : 2),
                    bucketTokens: tokens, bucketCost: costs)
            }
            return CompanionActivityRange(range: range, bucketStarts: dates, providers: providers)
        })

    static let demoSnapshot = CompanionSnapshot(
        sourceID: UUID(uuidString: "3FD01E8D-73C9-4546-A4A7-D0D6213EC3F5")!,
        sourceName: "Studio Mac", revision: 1, publishedAt: .now,
        providers: [
            CompanionProvider(
                name: "Claude", plan: "Max", capturedAt: .now,
                status: .available,
                windows: [
                    CompanionWindow(
                        id: "0:0", pool: nil, label: "5h", usedPercent: 68,
                        resetAt: .now.addingTimeInterval(7200), duration: 18000),
                    CompanionWindow(
                        id: "0:1", pool: nil, label: "Weekly", usedPercent: 42,
                        resetAt: .now.addingTimeInterval(172800), duration: 604800),
                ]),
            CompanionProvider(
                name: "Codex", plan: "Pro", capturedAt: .now.addingTimeInterval(-120),
                status: .available,
                windows: [
                    CompanionWindow(
                        id: "0:0", pool: nil, label: "5h", usedPercent: 24,
                        resetAt: .now.addingTimeInterval(10800), duration: 18000),
                    CompanionWindow(
                        id: "0:1", pool: nil, label: "Weekly", usedPercent: 81,
                        resetAt: .now.addingTimeInterval(259200), duration: 604800),
                ]),
        ], activity: demoActivity)
}
