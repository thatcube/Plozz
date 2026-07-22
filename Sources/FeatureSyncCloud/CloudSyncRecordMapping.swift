import Foundation
import CloudKit
import CoreModels

// MARK: - CloudSyncRecord <-> CKRecord mapping
//
// One `CloudSyncRecord` <-> one `CKRecord` of type `PlozzSyncConfig` in a single
// custom zone. Fields are deliberately flat + non-secret: `kind`, `entityID`,
// `version`, and the JSON `payload`. Nothing here can carry a token or password —
// the payloads come from the non-secret `SyncConfigSnapshot` only.

enum CloudSyncSchema {
    static let recordType = "PlozzSyncConfig"
    static let zoneName = "PlozzConfig"
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    static let fieldKind = "kind"
    static let fieldEntityID = "entityID"
    static let fieldVersion = "version"
    static let fieldPayload = "payload"

    static func recordID(forRecordName name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }
}

extension CloudSyncRecord {
    /// Populate a `CKRecord` (a fresh one, or a cached one carrying server system
    /// fields) with this record's fields.
    func populate(_ record: CKRecord) {
        record[CloudSyncSchema.fieldKind] = kind.rawValue as CKRecordValue
        record[CloudSyncSchema.fieldEntityID] = id as CKRecordValue
        record[CloudSyncSchema.fieldVersion] = Int64(version) as CKRecordValue
        record[CloudSyncSchema.fieldPayload] = payload as CKRecordValue
    }

    /// Decode a fetched `CKRecord` back into a `CloudSyncRecord`, or nil if it is
    /// malformed / from a newer schema we don't understand.
    init?(ckRecord record: CKRecord) {
        guard record.recordType == CloudSyncSchema.recordType,
              let kindRaw = record[CloudSyncSchema.fieldKind] as? String,
              let kind = CloudSyncRecord.Kind(rawValue: kindRaw),
              let id = record[CloudSyncSchema.fieldEntityID] as? String,
              let version = record[CloudSyncSchema.fieldVersion] as? Int64,
              let payload = record[CloudSyncSchema.fieldPayload] as? Data
        else { return nil }
        self.init(kind: kind, id: id, version: Int(version), payload: payload)
    }
}
