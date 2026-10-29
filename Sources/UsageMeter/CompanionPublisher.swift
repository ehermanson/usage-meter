import CloudKit
import CompanionKit
import Observation
import SwiftUI

extension ProviderUsage {
    /// Never export arbitrary error/setup text, paths, or CLI output.
    var companionValue: CompanionProvider {
        CompanionProvider(
            name: name, plan: plan, capturedAt: capturedAt,
            status: setup != nil
                ? .needsSetup : error != nil ? .temporarilyUnavailable : .available,
            windows: pools.flatMap { pool in
                pool.windows.map { window in
                    CompanionWindow(
                        id: Data(("\(pool.title ?? "")\u{1f}\(window.label)").utf8)
                            .base64EncodedString(), pool: pool.title,
                        label: window.label, usedPercent: window.usedPercent,
                        resetAt: window.resetAt, duration: window.duration)
                }
            },
            resetCredits: resetCredits.map {
                CompanionResetCredits(available: $0.available, earliestExpiry: $0.earliestExpiry)
            })
    }
}

@MainActor
@Observable
final class CompanionPublisher {
    static let shared = CompanionPublisher()
    private(set) var enabled: Bool
    private(set) var isBusy = false
    private(set) var lastUploaded: Date?
    private(set) var message: String?
    let sourceID: UUID
    var sourceName: String {
        didSet {
            defaults.set(sourceName, forKey: "companion.sourceName")
            submit(UsageStore.shared.providers)
        }
    }

    var connectionURL: URL { CompanionLink.url(sourceID: sourceID) }
    var configured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CompanionCloudEnabled") as? Bool == true
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var cloud: CloudSnapshotService?
    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    @ObservationIgnored private var pending: CompanionSnapshot?
    @ObservationIgnored private var lastSent: CompanionSnapshot?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    @ObservationIgnored private var deleting = false
    @ObservationIgnored private var epoch = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sourceID =
            defaults.string(forKey: "companion.sourceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(sourceID.uuidString, forKey: "companion.sourceID")
        sourceName = defaults.string(forKey: "companion.sourceName") ?? "My Mac"
        enabled = defaults.bool(forKey: "companion.enabled")
        lastUploaded = defaults.object(forKey: "companion.lastUploaded") as? Date
        accountID = defaults.string(forKey: "companion.accountID")
        pending = defaults.data(forKey: "companion.pending").flatMap {
            try? CompanionSnapshot.decode($0)
        }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.verifyAccountChange() }
        }
    }

    func setEnabled(_ value: Bool) {
        guard !deleting else { return }
        guard !value || configured else {
            message = CompanionError.notConfigured.localizedDescription
            return
        }
        enabled = value
        epoch += 1
        defaults.set(value, forKey: "companion.enabled")
        message = nil
        if value {
            retryAfter = .distantPast
            submit(UsageStore.shared.providers)
            Task { await ActivityStore.shared.refresh() }
        } else {
            pending = nil
            defaults.removeObject(forKey: "companion.pending")
        }
    }

    func submit(_ providers: [ProviderUsage]) {
        guard enabled, configured, !deleting else { return }
        let values = providers.filter(\.detected).map(\.companionValue)
        // Do not overwrite a restored upload with an empty launch placeholder.
        guard !providers.isEmpty else { retry(); return }
        let previous = pending ?? lastSent
        let activity = ActivityStore.shared.companionActivity ?? previous?.activity
        if previous?.providers != values || previous?.sourceName != sourceName
            || previous?.activity != activity
        {
            let revision = defaults.object(forKey: "companion.revision") as? Int64 ?? 0
            pending = CompanionSnapshot(
                sourceID: sourceID, sourceName: sourceName,
                revision: revision + 1, publishedAt: .now, providers: values, activity: activity)
            defaults.set(revision + 1, forKey: "companion.revision")
            // Persist only once bound to a verified account, never an unowned outbox.
            if accountID != nil { persistPending() }
        }
        retry()
    }

    func retry() {
        guard enabled, configured, !deleting, uploadTask == nil,
            pending != nil, Date.now >= retryAfter
        else { return }
        if cloud == nil { cloud = CloudSnapshotService() }
        guard let cloud else { return }
        isBusy = true
        let generation = epoch
        uploadTask = Task {
            defer { uploadTask = nil; isBusy = deleting; retry() }
            do {
                let identity = try await cloud.accountID()
                guard enabled, generation == epoch else { return }
                if let accountID, accountID != identity {
                    accountChanged()
                    return
                }
                accountID = identity
                defaults.set(identity, forKey: "companion.accountID")
                persistPending()
                while enabled, generation == epoch, let next = pending {
                    try await cloud.publish(next)
                    guard enabled, generation == epoch else { return }
                    lastSent = next
                    lastUploaded = .now
                    defaults.set(lastUploaded, forKey: "companion.lastUploaded")
                    failures = 0
                    message = nil
                    if pending?.revision == next.revision {
                        pending = nil
                        defaults.removeObject(forKey: "companion.pending")
                    }
                }
            } catch {
                guard generation == epoch else { return }
                failures += 1
                let serverDelay = (error as? CKError)?.retryAfterSeconds ?? 0
                retryAfter = .now.addingTimeInterval(
                    max(serverDelay, min(900, 30 * pow(2, Double(min(failures, 5))))))
                message =
                    "Upload paused. Check your iCloud account and network; Usage Meter will retry."
                if error is CompanionError { message = error.localizedDescription }
            }
        }
    }

    func deleteCloudData() async {
        guard configured, !deleting else { return }
        setEnabled(false)
        deleting = true
        isBusy = true
        defer { deleting = false; isBusy = false }
        // An in-flight save must finish before deleting, so it cannot resurrect data.
        await uploadTask?.value
        if cloud == nil { cloud = CloudSnapshotService() }
        do {
            guard let cloud else { return }
            let identity = try await cloud.accountID()
            guard accountID == nil || accountID == identity else { accountChanged(); return }
            try await cloud.delete(sourceID)
            lastSent = nil
            lastUploaded = nil
            defaults.removeObject(forKey: "companion.lastUploaded")
            message = "This Mac's cloud snapshot has been deleted."
        } catch {
            message = "Couldn't delete the cloud snapshot. Check iCloud and try again."
        }
    }

    private func persistPending() {
        defaults.set(pending.flatMap { try? JSONEncoder().encode($0) }, forKey: "companion.pending")
    }

    private func verifyAccountChange() async {
        guard configured, enabled else { return }
        if cloud == nil { cloud = CloudSnapshotService() }
        guard let cloud else { return }
        let generation = epoch
        do {
            let identity = try await cloud.accountID()
            guard generation == epoch else { return }
            if let accountID, accountID != identity {
                accountChanged()
            } else {
                retryAfter = .distantPast
                submit(UsageStore.shared.providers)
            }
        } catch {
            guard generation == epoch else { return }
            // A notification can describe a transient account-status change.
            // Keep the account-bound outbox until identity can be verified again.
            if (error as? CompanionError) == .noAccount {
                accountChanged()
            }
        }
    }

    private func accountChanged() {
        epoch += 1
        enabled = false
        pending = nil
        lastSent = nil
        accountID = nil
        lastUploaded = nil
        for key in ["enabled", "pending", "accountID", "lastUploaded"] {
            defaults.removeObject(forKey: "companion.\(key)")
        }
        message = "Your iCloud account changed. Enable sync again to share with this account."
    }
}
