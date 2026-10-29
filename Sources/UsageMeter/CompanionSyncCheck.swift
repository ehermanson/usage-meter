import CompanionKit
import Foundation

/// A signed-build diagnostic that uses only synthetic data, then deletes it.
/// It never reads provider credentials or logs.
enum CompanionSyncCheck {
    static func run(holdForPhone: Bool = false) async -> Int32 {
        guard Bundle.main.object(forInfoDictionaryKey: "CompanionCloudEnabled") as? Bool == true
        else {
            print("Sync check requires the signed CloudKit Mac target.")
            return 1
        }
        let cloud = CloudSnapshotService()
        let source = UUID()
        do {
            _ = try await cloud.accountID()
            let observed = Date.now
            let sample = CompanionSnapshot(
                sourceID: source, sourceName: "Sync check (synthetic)",
                revision: 1, publishedAt: observed,
                providers: [
                    CompanionProvider(
                        name: "Claude", plan: "Synthetic", capturedAt: observed,
                        status: .available,
                        windows: [
                            CompanionWindow(
                                id: "5h", pool: nil, label: "5h", usedPercent: 42,
                                resetAt: observed.addingTimeInterval(7200), duration: 18000)
                        ])
                ],
                activity: CompanionActivity(
                    capturedAt: observed, timeZoneIdentifier: "UTC",
                    ranges: [
                        CompanionActivityRange(
                            range: .week, bucketStarts: [observed],
                            providers: [
                                CompanionProviderActivity(
                                    name: "Claude", tokens: 1000,
                                    cost: 0.02, unpricedTokens: 0, sessions: 1,
                                    bucketTokens: [1000], bucketCost: [0.02])
                            ])
                    ]))
            try await cloud.publish(sample)
            let received = try await cloud.fetch(source)
            guard received == sample else { throw CompanionError.invalidSnapshot }
            if holdForPhone {
                print("Phone test link: \(CompanionLink.url(sourceID: source).absoluteString)")
                print("Synthetic snapshot will be deleted automatically in two minutes.")
                fflush(stdout)
                try await Task.sleep(for: .seconds(120))
            }
            try await cloud.delete(source)
            print("CloudKit publish, encrypted snapshot fetch, and delete succeeded.")
            return 0
        } catch {
            try? await cloud.delete(source)
            print("CloudKit sync check failed: \(error.localizedDescription)")
            return 1
        }
    }
}
