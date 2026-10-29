import CloudKit
import Foundation

/// Single-writer snapshots need neither an object graph nor a two-way merge.
/// Explicit reads/writes keep foreground refresh deterministic; callers persist
/// the latest pending upload and retry. No container is constructed until opt-in.
public actor CloudSnapshotService {
    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID = CKRecordZone.ID(zoneName: CompanionConfiguration.zone)

    public init() {
        let container = CKContainer(identifier: CompanionConfiguration.container)
        self.container = container
        self.database = container.privateCloudDatabase
    }

    public func accountID() async throws -> String {
        switch try await container.accountStatus() {
        case .available:
            return try await container.userRecordID().recordName
        case .noAccount, .restricted:
            throw CompanionError.noAccount
        case .couldNotDetermine, .temporarilyUnavailable:
            throw CKError(.serviceUnavailable)
        @unknown default:
            throw CKError(.serviceUnavailable)
        }
    }

    public func publish(_ snapshot: CompanionSnapshot) async throws {
        _ = try snapshot.validated()
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        let record = CKRecord(
            recordType: CompanionConfiguration.recordType,
            recordID: recordID(snapshot.sourceID))
        record.encryptedValues["payload"] = try JSONEncoder().encode(snapshot) as NSData
        let result = try await database.modifyRecords(
            saving: [record], deleting: [],
            savePolicy: .allKeys, atomically: true)
        guard let saved = result.saveResults[record.recordID] else {
            throw CompanionError.invalidSnapshot
        }
        _ = try saved.get()
    }

    public func fetch(_ sourceID: UUID) async throws -> CompanionSnapshot {
        do {
            return try decode(await database.record(for: recordID(sourceID)))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
        {
            throw CompanionError.sourceNotFound
        }
    }

    public func discover() async throws -> [CompanionSnapshot] {
        var snapshots: [CKRecord.ID: CompanionSnapshot] = [:]
        do {
            var token: CKServerChangeToken?
            while true {
                // Zone changes avoid query-index lag during QR onboarding and
                // require no queryable indexes on the encrypted payload.
                let page = try await database.recordZoneChanges(
                    inZoneWith: zoneID,
                    since: token, resultsLimit: 100)
                for (id, result) in page.modificationResultsByID {
                    let record = try result.get().record
                    if record.recordType == CompanionConfiguration.recordType {
                        snapshots[id] = try decode(record)
                    }
                }
                for deletion in page.deletions { snapshots.removeValue(forKey: deletion.recordID) }
                guard page.moreComing else { break }
                token = page.changeToken
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            return []
        }
        return snapshots.values.sorted {
            $0.sourceName.localizedStandardCompare($1.sourceName) == .orderedAscending
        }
    }

    public func delete(_ sourceID: UUID) async throws {
        do {
            _ = try await database.deleteRecord(withID: recordID(sourceID))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
        {
            // Already removed.
        }
    }

    public func subscribe() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: "companion-v1")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    private func recordID(_ sourceID: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: sourceID.uuidString, zoneID: zoneID)
    }

    private func decode(_ record: CKRecord) throws -> CompanionSnapshot {
        guard let data = record.encryptedValues["payload"] as? Data else {
            throw CompanionError.invalidSnapshot
        }
        let snapshot = try CompanionSnapshot.decode(data)
        guard record.recordID.recordName == snapshot.sourceID.uuidString else {
            throw CompanionError.invalidSnapshot
        }
        return snapshot
    }
}
