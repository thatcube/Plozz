import Foundation
import CloudKit
import CoreModels

// MARK: - CloudKit schema + SyncLedger <-> CKRecord mapping
//
// One CKRecord per synced entity in a single custom zone. The record NAME is the
// ledger's `SyncRecordID` (e.g. "profile:<id>", "setting:<pid>:<key>"), so CloudKit's
// own record identity IS the sync key — no separate id field to drift. Fields are
// flat and NON-SECRET: the entity kind, the canonical value blob, and the
// mutation-boundary edit clock. Nothing here can carry a token.
//
// Config V3 keeps its original type, zone, and fields. Additional descriptors use
// disjoint zones/types while sharing this mapping and service implementation.

public struct CloudSyncSchemaDescriptor: Sendable, Equatable {
    public enum KindDerivation: Sendable, Equatable {
        case syncRecordKey
        case prefixBeforeFirstColon
    }

    public let recordType: String
    public let zoneName: String
    public let fieldKind: String
    public let fieldValue: String
    public let fieldEditedAt: String
    public let legacyZoneNames: [String]
    public let kindDerivation: KindDerivation

    public init(
        recordType: String,
        zoneName: String,
        fieldKind: String = "kind",
        fieldValue: String = "value",
        fieldEditedAt: String = "editedAt",
        legacyZoneNames: [String] = [],
        kindDerivation: KindDerivation = .prefixBeforeFirstColon
    ) {
        self.recordType = recordType
        self.zoneName = zoneName
        self.fieldKind = fieldKind
        self.fieldValue = fieldValue
        self.fieldEditedAt = fieldEditedAt
        self.legacyZoneNames = legacyZoneNames
        self.kindDerivation = kindDerivation
    }

    public static let configV3 = CloudSyncSchemaDescriptor(
        recordType: "PlozzSyncV3",
        zoneName: "PlozzSyncV3Zone",
        legacyZoneNames: ["PlozzConfig", "PlozzConfigV2"],
        kindDerivation: .syncRecordKey
    )

    public static let mediaStateV1 = CloudSyncSchemaDescriptor(
        recordType: "PlozzMediaStateV1Record",
        zoneName: "PlozzMediaStateV1Zone",
        kindDerivation: .prefixBeforeFirstColon
    )

    public var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName)
    }

    public var legacyZoneIDs: [CKRecordZone.ID] {
        legacyZoneNames.map { CKRecordZone.ID(zoneName: $0) }
    }

    public func recordID(forRecordName name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    public func contains(_ recordID: CKRecord.ID) -> Bool {
        recordID.zoneID.zoneName == zoneName
    }

    public func matches(_ record: CKRecord) -> Bool {
        record.recordType == recordType && contains(record.recordID)
    }

    public func kind(forRecordName name: String) -> String {
        switch kindDerivation {
        case .syncRecordKey:
            return SyncRecordKey.parse(name)?.kind.rawValue ?? "unknown"
        case .prefixBeforeFirstColon:
            guard let separator = name.firstIndex(of: ":"), separator != name.startIndex else {
                return "unknown"
            }
            return String(name[..<separator])
        }
    }

    func userDefaultsKey(prefix: String, containerIdentifier: String) -> String {
        let base = "\(prefix).\(containerIdentifier)"
        guard self != .configV3 else { return base }
        return "\(base).\(zoneName).\(recordType)"
    }

    /// Bridge an integer field back regardless of how CloudKit boxed it (Int / Int64 /
    /// NSNumber), so a valid record is never silently dropped on fetch.
    public func int64(_ value: Any?) -> Int64? {
        (value as? Int64) ?? (value as? Int).map(Int64.init) ?? (value as? NSNumber)?.int64Value
    }
}

/// Compatibility aliases for the original config V3 schema.
enum CloudSyncSchema {
    private static let descriptor = CloudSyncSchemaDescriptor.configV3

    static let recordType = descriptor.recordType
    static let zoneName = descriptor.zoneName
    static var zoneID: CKRecordZone.ID { descriptor.zoneID }
    static let legacyZoneNames = descriptor.legacyZoneNames
    static var legacyZoneIDs: [CKRecordZone.ID] { descriptor.legacyZoneIDs }
    static let fieldKind = descriptor.fieldKind
    static let fieldValue = descriptor.fieldValue
    static let fieldEditedAt = descriptor.fieldEditedAt

    static func recordID(forRecordName name: String) -> CKRecord.ID {
        descriptor.recordID(forRecordName: name)
    }

    static func int64(_ value: Any?) -> Int64? {
        descriptor.int64(value)
    }
}

extension SyncUpload {
    /// Populate a CKRecord (fresh, or one carrying cached server system fields) from
    /// this upload.
    public func populate(
        _ record: CKRecord,
        schema: CloudSyncSchemaDescriptor
    ) {
        record[schema.fieldKind] = schema.kind(forRecordName: recordName) as CKRecordValue
        record[schema.fieldValue] = value as CKRecordValue
        record[schema.fieldEditedAt] = editedAt as CKRecordValue
    }

    func populate(_ record: CKRecord) {
        populate(record, schema: .configV3)
    }
}

extension SyncRemoteRecord {
    /// Decode a fetched CKRecord into a `SyncRemoteRecord`, or nil if it isn't a valid
    /// schema record (wrong type/zone, or malformed — the caller logs those, never drops
    /// silently).
    public init?(
        ckRecord record: CKRecord,
        schema: CloudSyncSchemaDescriptor
    ) {
        guard schema.matches(record),
              let value = record[schema.fieldValue] as? Data,
              let editedAt = schema.int64(record[schema.fieldEditedAt])
        else { return nil }
        self.init(
            recordName: record.recordID.recordName,
            value: value, editedAt: editedAt,
            systemFields: CloudSyncSystemFields.archive(record))
    }

    init?(ckRecord record: CKRecord) {
        self.init(ckRecord: record, schema: .configV3)
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
