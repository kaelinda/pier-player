@preconcurrency import CloudKit
import Foundation
import Security

enum CloudKitEntitlement {
    static let requiredContainerIdentifier = "iCloud.dev.pierplayer.app"

    static func includesRequiredContainer(_ value: Any?) -> Bool {
        guard let identifiers = value as? [String] else { return false }
        return identifiers.contains(requiredContainerIdentifier)
    }

    static func currentValue() -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        let key = "com.apple.developer.icloud-container-identifiers" as CFString
        return SecTaskCopyValueForEntitlement(task, key, nil)
    }
}

enum CloudKitRecordMapper {
    static let sourceRecordType = "SMBSource"
    static let progressRecordType = "PlaybackProgress"

    static func record(for source: SyncedSMBSource) -> CKRecord {
        let record = CKRecord(recordType: sourceRecordType, recordID: .init(recordName: source.id.uuidString))
        record["schemaVersion"] = NSNumber(value: 1)
        record["displayName"] = source.displayName as CKRecordValue
        record["host"] = source.host as CKRecordValue
        record["share"] = source.share as CKRecordValue
        if let domain = source.domain { record["domain"] = domain as CKRecordValue }
        record["requiresEncryption"] = NSNumber(value: source.requiresEncryption)
        record["clientModifiedAt"] = source.modifiedAt as CKRecordValue
        record["isDeleted"] = NSNumber(value: source.isDeleted)
        return record
    }

    static func deletionRecord(id: UUID, modifiedAt: Date) -> CKRecord {
        let record = CKRecord(recordType: sourceRecordType, recordID: .init(recordName: id.uuidString))
        record["schemaVersion"] = NSNumber(value: 1)
        record["clientModifiedAt"] = modifiedAt as CKRecordValue
        record["isDeleted"] = NSNumber(value: true)
        return record
    }

    static func source(from record: CKRecord) throws -> SyncedSMBSource {
        guard record.recordType == sourceRecordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let modifiedAt = record["clientModifiedAt"] as? Date else {
            throw CloudSyncError.invalidRemoteRecord
        }
        let isDeleted = (record["isDeleted"] as? NSNumber)?.boolValue ?? false
        if isDeleted {
            return SyncedSMBSource(
                id: id,
                displayName: "",
                host: "",
                share: "",
                domain: nil,
                requiresEncryption: false,
                modifiedAt: modifiedAt,
                isDeleted: true
            )
        }
        guard let displayName = record["displayName"] as? String,
              let host = record["host"] as? String,
              let share = record["share"] as? String,
              !displayName.isEmpty, !host.isEmpty, !share.isEmpty else {
            throw CloudSyncError.invalidRemoteRecord
        }
        return SyncedSMBSource(
            id: id,
            displayName: displayName,
            host: host,
            share: share,
            domain: record["domain"] as? String,
            requiresEncryption: (record["requiresEncryption"] as? NSNumber)?.boolValue ?? false,
            modifiedAt: modifiedAt
        )
    }

    static func record(for progress: PlaybackProgress) -> CKRecord {
        let record = CKRecord(recordType: progressRecordType, recordID: .init(recordName: progress.mediaID))
        record["schemaVersion"] = NSNumber(value: 1)
        record["sourceID"] = progress.sourceID.uuidString as CKRecordValue
        record["position"] = NSNumber(value: progress.position)
        record["duration"] = NSNumber(value: progress.duration)
        record["completed"] = NSNumber(value: progress.isCompleted)
        record["clientModifiedAt"] = progress.modifiedAt as CKRecordValue
        return record
    }

    static func progress(from record: CKRecord) throws -> PlaybackProgress {
        guard record.recordType == progressRecordType,
              let sourceString = record["sourceID"] as? String,
              let sourceID = UUID(uuidString: sourceString),
              let position = (record["position"] as? NSNumber)?.doubleValue,
              let duration = (record["duration"] as? NSNumber)?.doubleValue,
              let modifiedAt = record["clientModifiedAt"] as? Date else {
            throw CloudSyncError.invalidRemoteRecord
        }
        do {
            return try PlaybackProgress(
                mediaID: record.recordID.recordName,
                sourceID: sourceID,
                position: position,
                duration: duration,
                modifiedAt: modifiedAt,
                isCompleted: (record["completed"] as? NSNumber)?.boolValue ?? false
            )
        } catch {
            throw CloudSyncError.invalidRemoteRecord
        }
    }
}

public actor CloudKitSyncTransport: CloudSyncTransport {
    private let container: CKContainer
    private let database: CKDatabase

    public static func makeIfEntitled() -> CloudKitSyncTransport? {
        guard CloudKitEntitlement.includesRequiredContainer(
            CloudKitEntitlement.currentValue()
        ) else {
            return nil
        }
        return CloudKitSyncTransport(container: CKContainer(
            identifier: CloudKitEntitlement.requiredContainerIdentifier
        ))
    }

    public init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    public func fetchSnapshot() async throws -> CloudSyncSnapshot {
        do {
            let sourceRecords = try await records(type: CloudKitRecordMapper.sourceRecordType)
            let progressRecords = try await records(type: CloudKitRecordMapper.progressRecordType)
            return try CloudSyncSnapshot(
                sources: sourceRecords.map(CloudKitRecordMapper.source(from:)),
                progress: progressRecords.map(CloudKitRecordMapper.progress(from:))
            )
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw map(error)
        }
    }

    public func save(_ mutations: [CloudSyncMutation]) async throws {
        let records = mutations.map { mutation -> CKRecord in
            switch mutation {
            case let .upsertSource(source): CloudKitRecordMapper.record(for: source)
            case let .deleteSource(id, modifiedAt):
                CloudKitRecordMapper.deletionRecord(id: id, modifiedAt: modifiedAt)
            case let .upsertProgress(progress): CloudKitRecordMapper.record(for: progress)
            }
        }
        do {
            let result = try await database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            for saveResult in result.saveResults.values { _ = try saveResult.get() }
        } catch {
            throw map(error)
        }
    }

    private func records(type: String) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        var page = try await database.records(matching: query)
        var output = try page.matchResults.map { try $0.1.get() }
        while let cursor = page.queryCursor {
            page = try await database.records(continuingMatchFrom: cursor)
            output.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        }
        return output
    }

    private func map(_ error: Error) -> CloudSyncError {
        guard let cloudError = error as? CKError else { return .temporarilyUnavailable }
        return switch cloudError.code {
        case .notAuthenticated: .accountUnavailable
        case .missingEntitlement: .entitlementMissing
        case .networkFailure, .networkUnavailable, .requestRateLimited,
             .serviceUnavailable, .zoneBusy: .temporarilyUnavailable
        default: .temporarilyUnavailable
        }
    }
}
