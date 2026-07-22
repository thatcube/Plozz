import Foundation
import CloudKit
import CoreModels

// MARK: - V3 CloudKit schema + SyncLedger <-> CKRecord mapping
//
// One CKRecord per synced entity in a single custom zone. The record NAME is the
// ledger's `SyncRecordID` (e.g. "profile:<id>", "setting:<pid>:<key>"), so CloudKit's
// own record identity IS the sync key — no separate id field to drift. Fields are
// flat and NON-SECRET: the entity kind, the canonical value blob, and the
// mutation-boundary edit clock. Nothing here can carry a token.
//
// Fresh record type + zone (V3) so any leftover V1/V2 records are simply a different
// type in a different zone and are never confused with V3 data (the V2 "13 decode
// failures" were exactly old-schema records the decoder rejected).

enum CloudSyncSchema {
    static let recordType = "PlozzSyncV3"
    static let zoneName = "PlozzSyncV3Zone"
    static var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName) }

    /// Dead zones from the V1/V2 sync engines. Their records are ignored by V3 but,
    /// left in the private DB, they get dragged into every fetch as noise (and inflate
    /// the user-visible item count). Deleted once by the V3 service.
    static let legacyZoneNames = ["PlozzConfig", "PlozzConfigV2"]
    static var legacyZoneIDs: [CKRecordZone.ID] { legacyZoneNames.map { CKRecordZone.ID(zoneName: $0) } }

    static let fieldKind = "kind"        // SyncRecordKind raw value (diagnostics/filtering)
    static let fieldValue = "value"      // canonical value bytes
    static let fieldEditedAt = "editedAt" // Int64 mutation clock

    static func recordID(forRecordName name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// Bridge an integer field back regardless of how CloudKit boxed it (Int / Int64 /
    /// NSNumber), so a valid record is never silently dropped on fetch.
    static func int64(_ value: Any?) -> Int64? {
        (value as? Int64) ?? (value as? Int).map(Int64.init) ?? (value as? NSNumber)?.int64Value
    }
}

extension SyncUpload {
    /// Populate a CKRecord (fresh, or one carrying cached server system fields) from
    /// this upload.
    func populate(_ record: CKRecord) {
        let kind = SyncRecordKey.parse(recordName)?.kind.rawValue ?? "unknown"
        record[CloudSyncSchema.fieldKind] = kind as CKRecordValue
        record[CloudSyncSchema.fieldValue] = value as CKRecordValue
        record[CloudSyncSchema.fieldEditedAt] = editedAt as CKRecordValue
    }
}

extension SyncRemoteRecord {
    /// Decode a fetched CKRecord into a `SyncRemoteRecord`, or nil if it isn't a valid
    /// V3 record (wrong type/zone, or malformed — the caller logs those, never drops
    /// silently).
    init?(ckRecord record: CKRecord) {
        guard record.recordType == CloudSyncSchema.recordType,
              record.recordID.zoneID.zoneName == CloudSyncSchema.zoneName,
              let value = record[CloudSyncSchema.fieldValue] as? Data,
              let editedAt = CloudSyncSchema.int64(record[CloudSyncSchema.fieldEditedAt])
        else { return nil }
        self.init(
            recordName: record.recordID.recordName,
            value: value, editedAt: editedAt,
            systemFields: CloudSyncSystemFields.archive(record))
    }
}

// MARK: - CKRecord system-field archiving (change-tag persistence)

enum CloudSyncSystemFields {
    /// Archive ONLY the system fields (record id + change tag), so a later save carries
    /// the correct tag for conflict detection. MUST use encodeSystemFields (not the
    /// whole record) and decode via CKRecord(coder:).
    static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// Rebuild a bare CKRecord carrying the cached change tag, or nil.
    static func record(from data: Data?) -> CKRecord? {
        guard let data else { return nil }
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }
}
