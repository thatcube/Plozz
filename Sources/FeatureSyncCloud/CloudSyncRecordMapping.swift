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
    // V2: HLC-timestamp (editedAt) model. A fresh record type + zone name so any
    // records/mirrors from the earlier (never-working) version model are ignored
    // rather than migrated — there is no real user data to preserve.
    static let recordType = "PlozzSyncConfigV2"
    static let zoneName = "PlozzConfigV2"
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    static let fieldKind = "kind"
    static let fieldEntityID = "entityID"
    static let fieldEditedAt = "editedAt"
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
        record[CloudSyncSchema.fieldEditedAt] = editedAt as CKRecordValue
        record[CloudSyncSchema.fieldPayload] = payload as CKRecordValue
    }

    /// Decode a fetched `CKRecord` back into a `CloudSyncRecord`, or nil if it is
    /// malformed / from a newer schema we don't understand.
    init?(ckRecord record: CKRecord) {
        guard record.recordType == CloudSyncSchema.recordType,
              let kindRaw = record[CloudSyncSchema.fieldKind] as? String,
              let kind = CloudSyncRecord.Kind(rawValue: kindRaw),
              let id = record[CloudSyncSchema.fieldEntityID] as? String,
              let payload = record[CloudSyncSchema.fieldPayload] as? Data
        else { return nil }
        // CloudKit can bridge an integer field back as Int, Int64, or NSNumber
        // depending on platform/path; accept any of them rather than dropping the
        // record (a failed `as? Int64` silently loses that update on fetch).
        let editedAtValue = record[CloudSyncSchema.fieldEditedAt]
        guard let editedAt = (editedAtValue as? Int64)
            ?? (editedAtValue as? Int).map(Int64.init)
            ?? (editedAtValue as? NSNumber)?.int64Value
        else { return nil }
        self.init(kind: kind, id: id, editedAt: editedAt, payload: payload)
    }
}
