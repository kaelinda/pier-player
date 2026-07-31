import CloudKit
import Foundation
import Testing
@testable import CloudSyncKit

@Test func sourceRecordContainsOnlyApprovedNonSecretFields() throws {
    let source = SyncedSMBSource(
        id: UUID(),
        displayName: "Living Room",
        host: "nas.local",
        share: "PrivateMedia",
        domain: "WORKGROUP",
        requiresEncryption: true,
        modifiedAt: Date(timeIntervalSince1970: 10)
    )

    let record = CloudKitRecordMapper.record(for: source)
    let keys = Set(record.allKeys())

    #expect(record.recordType == "SMBSource")
    #expect(record.recordID.recordName == source.id.uuidString)
    #expect(keys == Set([
        "schemaVersion", "displayName", "host", "share", "domain",
        "requiresEncryption", "clientModifiedAt", "isDeleted",
    ]))
    #expect(!keys.contains("username"))
    #expect(!keys.contains("password"))
    #expect(try CloudKitRecordMapper.source(from: record) == source)
}

@Test func progressRecordContainsNoMediaPathAndRoundTrips() throws {
    let progress = try PlaybackProgress(
        mediaID: String(repeating: "c", count: 64),
        sourceID: UUID(),
        position: 42,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 20)
    )

    let record = CloudKitRecordMapper.record(for: progress)
    let keys = Set(record.allKeys())

    #expect(record.recordType == "PlaybackProgress")
    #expect(keys == Set([
        "schemaVersion", "sourceID", "position", "duration",
        "completed", "clientModifiedAt",
    ]))
    #expect(!keys.contains("path"))
    #expect(try CloudKitRecordMapper.progress(from: record) == progress)
}

@Test func malformedCloudRecordIsRejectedWithoutFreeFormData() {
    let record = CKRecord(
        recordType: "PlaybackProgress",
        recordID: CKRecord.ID(recordName: "not-a-digest")
    )
    record["position"] = Double.infinity as CKRecordValue
    record["duration"] = 100 as CKRecordValue

    #expect(throws: CloudSyncError.invalidRemoteRecord) {
        try CloudKitRecordMapper.progress(from: record)
    }
}
