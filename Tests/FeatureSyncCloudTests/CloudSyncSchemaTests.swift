import XCTest
import CloudKit
@testable import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncSchemaTests: XCTestCase {

    func testConfigV3ConstantsRemainUnchanged() {
        let schema = CloudSyncSchemaDescriptor.configV3

        XCTAssertEqual(schema.recordType, "PlozzSyncV3")
        XCTAssertEqual(schema.zoneName, "PlozzSyncV3Zone")
        XCTAssertEqual(schema.fieldKind, "kind")
        XCTAssertEqual(schema.fieldValue, "value")
        XCTAssertEqual(schema.fieldEditedAt, "editedAt")
        XCTAssertEqual(schema.legacyZoneNames, ["PlozzConfig", "PlozzConfigV2"])
    }

    func testMediaStateSchemaIsIsolatedFromConfigV3() {
        let media = CloudSyncSchemaDescriptor.mediaStateV1
        let config = CloudSyncSchemaDescriptor.configV3

        XCTAssertEqual(media.recordType, "PlozzMediaStateV1Record")
        XCTAssertEqual(media.zoneName, "PlozzMediaStateV1Zone")
        XCTAssertEqual(media.fieldKind, "kind")
        XCTAssertEqual(media.fieldValue, "value")
        XCTAssertEqual(media.fieldEditedAt, "editedAt")
        XCTAssertTrue(media.legacyZoneNames.isEmpty)
        XCTAssertNotEqual(media.recordType, config.recordType)
        XCTAssertNotEqual(media.zoneID, config.zoneID)
        XCTAssertEqual(
            config.userDefaultsKey(prefix: "inventory", containerIdentifier: "iCloud.test"),
            "inventory.iCloud.test"
        )
        XCTAssertNotEqual(
            media.userDefaultsKey(prefix: "inventory", containerIdentifier: "iCloud.test"),
            config.userDefaultsKey(prefix: "inventory", containerIdentifier: "iCloud.test")
        )
    }

    func testUploadPopulatesAndDecodesRoundTrip() {
        let name = SyncRecordKey(kind: .profile, id: "P1").recordName
        let value = Data(#"{"a":1,"name":"Kid"}"#.utf8)
        let up = SyncUpload(recordName: name, value: value, editedAt: 4242, systemFields: nil)

        let record = CKRecord(recordType: CloudSyncSchema.recordType,
                              recordID: CloudSyncSchema.recordID(forRecordName: name))
        up.populate(record)

        // Decoding the populated record reproduces the value + editedAt.
        let decoded = SyncRemoteRecord(ckRecord: record)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.recordName, name)
        XCTAssertEqual(decoded?.value, value)
        XCTAssertEqual(decoded?.editedAt, 4242)
        XCTAssertEqual(record[CloudSyncSchema.fieldKind] as? String, "profile")
    }

    func testExplicitConfigDescriptorPopulatesAndDecodes() {
        let schema = CloudSyncSchemaDescriptor.configV3
        let name = SyncRecordKey(kind: .setting, id: "P1:theme").recordName
        let value = Data("dark".utf8)
        let upload = SyncUpload(
            recordName: name,
            value: value,
            editedAt: 12,
            systemFields: nil
        )
        let record = CKRecord(
            recordType: schema.recordType,
            recordID: schema.recordID(forRecordName: name)
        )

        upload.populate(record, schema: schema)
        let decoded = SyncRemoteRecord(ckRecord: record, schema: schema)

        XCTAssertEqual(record[schema.fieldKind] as? String, "setting")
        XCTAssertEqual(decoded?.recordName, name)
        XCTAssertEqual(decoded?.value, value)
        XCTAssertEqual(decoded?.editedAt, 12)
    }

    func testMediaDescriptorPopulatesAndDecodesAliasRecord() {
        let schema = CloudSyncSchemaDescriptor.mediaStateV1
        let name = "alias:profile-1:8F873DC8-7146-4F04-B36A-21888EAFE77C"
        let value = Data(#"{"watched":true}"#.utf8)
        let upload = SyncUpload(
            recordName: name,
            value: value,
            editedAt: 99,
            systemFields: nil
        )
        let record = CKRecord(
            recordType: schema.recordType,
            recordID: schema.recordID(forRecordName: name)
        )

        upload.populate(record, schema: schema)
        let decoded = SyncRemoteRecord(ckRecord: record, schema: schema)

        XCTAssertEqual(record[schema.fieldKind] as? String, "alias")
        XCTAssertEqual(decoded?.recordName, name)
        XCTAssertEqual(decoded?.value, value)
        XCTAssertEqual(decoded?.editedAt, 99)
    }

    func testCrossSchemaDecodeIsRejected() {
        let config = CloudSyncSchemaDescriptor.configV3
        let media = CloudSyncSchemaDescriptor.mediaStateV1
        let configRecord = populatedRecord(schema: config, name: "profile:1")
        let mediaRecord = populatedRecord(schema: media, name: "alias:profile-1:id")

        XCTAssertNil(SyncRemoteRecord(ckRecord: configRecord, schema: media))
        XCTAssertNil(SyncRemoteRecord(ckRecord: mediaRecord, schema: config))
    }

    func testMediaServiceExposesOnlyMediaSchemaTargets() {
        let configuration = CloudConfigSyncService.Configuration(
            containerIdentifier: "iCloud.com.thatcube.Plozz",
            stateFileURL: URL(fileURLWithPath: "unused-media-cloud-state.json"),
            schema: .mediaStateV1,
            isEnabled: { false },
            captureRecords: { _ in [:] },
            applyRecords: { _ in }
        )
        let service = CloudConfigSyncService(configuration)
        let recordID = service.schema.recordID(forRecordName: "alias:profile-1:id")

        XCTAssertEqual(service.schema.recordType, "PlozzMediaStateV1Record")
        XCTAssertEqual(recordID.zoneID.zoneName, "PlozzMediaStateV1Zone")
        XCTAssertNotEqual(service.schema.recordType, CloudSyncSchema.recordType)
        XCTAssertNotEqual(recordID.zoneID, CloudSyncSchema.zoneID)
        XCTAssertTrue(service.schema.legacyZoneIDs.isEmpty)
    }

    func testServiceConfigurationDefaultsToConfigV3() {
        let configuration = CloudConfigSyncService.Configuration(
            containerIdentifier: "iCloud.com.thatcube.Plozz",
            stateFileURL: URL(fileURLWithPath: "unused-config-cloud-state.json"),
            isEnabled: { false },
            captureRecords: { _ in [:] },
            applyRecords: { _ in }
        )

        XCTAssertEqual(configuration.schema, .configV3)
    }

    /// Apple permits exactly one active `CKSyncEngine` per private database, so
    /// Config V3 and `PlozzMediaStateV1` must be multiplexed onto ONE
    /// `CloudConfigSyncService` instead of two separate service instances. This
    /// constructs the service the way the app shells do (a primary Config V3
    /// `Configuration` plus a media-state `ChannelConfiguration`) and asserts the
    /// two channels' schemas/state files are exposed and fully disjoint, while the
    /// primary channel's own defaults remain exactly as before multiplexing.
    /// Construction never touches `CKContainer` (it's built lazily), so this is
    /// safe to run in a unit-test host with no iCloud entitlement.
    func testOneServiceMultiplexesConfigAndMediaChannelsWithDisjointSchemasAndStateFiles() {
        let mediaChannel = CloudConfigSyncService.ChannelConfiguration(
            schema: .mediaStateV1,
            stateFileURL: URL(fileURLWithPath: "unused-media-cloud-state.json"),
            captureRecords: { fallback in fallback },
            applyRecords: { _ in }
        )
        let configuration = CloudConfigSyncService.Configuration(
            containerIdentifier: "iCloud.com.thatcube.Plozz",
            stateFileURL: URL(fileURLWithPath: "unused-config-cloud-state.json"),
            isEnabled: { false },
            captureRecords: { _ in [:] },
            applyRecords: { _ in }
        )
        let service = CloudConfigSyncService(configuration, channels: [mediaChannel])

        // Primary channel's convenience properties are unchanged by multiplexing.
        XCTAssertEqual(service.schema, .configV3)
        XCTAssertEqual(service.stateFileURL.lastPathComponent, "unused-config-cloud-state.json")

        // Both channels are exposed, primary first, and are fully disjoint.
        XCTAssertEqual(service.channelSchemas, [.configV3, .mediaStateV1])
        XCTAssertEqual(
            service.channelStateFileURLs.map(\.lastPathComponent),
            ["unused-config-cloud-state.json", "unused-media-cloud-state.json"]
        )
        XCTAssertEqual(
            Set(service.channelStateFileURLs).count, service.channelStateFileURLs.count,
            "channel state files must be disjoint"
        )
        let zoneNames = service.channelSchemas.map(\.zoneName)
        XCTAssertEqual(Set(zoneNames).count, zoneNames.count, "channel schemas must be disjoint")
    }

    func testDecodeRejectsWrongRecordType() {
        let id = CloudSyncSchema.recordID(forRecordName: "profile:1")
        let record = CKRecord(recordType: "SomeOtherType", recordID: id)
        record[CloudSyncSchema.fieldValue] = Data([1, 2, 3]) as CKRecordValue
        record[CloudSyncSchema.fieldEditedAt] = Int64(1) as CKRecordValue
        XCTAssertNil(SyncRemoteRecord(ckRecord: record), "must reject non-V3 record types")
    }

    func testDecodeRejectsMissingFields() {
        let id = CloudSyncSchema.recordID(forRecordName: "profile:1")
        let record = CKRecord(recordType: CloudSyncSchema.recordType, recordID: id)
        // No value / editedAt set.
        XCTAssertNil(SyncRemoteRecord(ckRecord: record), "must reject records missing required fields")
    }

    func testInt64BridgeAcceptsIntAndNSNumber() {
        XCTAssertEqual(CloudSyncSchema.int64(Int64(7)), 7)
        XCTAssertEqual(CloudSyncSchema.int64(Int(7)), 7)
        XCTAssertEqual(CloudSyncSchema.int64(NSNumber(value: 7)), 7)
        XCTAssertNil(CloudSyncSchema.int64("nope"))
    }

    func testSystemFieldsArchiveRoundTrip() {
        let id = CloudSyncSchema.recordID(forRecordName: "profile:1")
        let record = CKRecord(recordType: CloudSyncSchema.recordType, recordID: id)
        let data = CloudSyncSystemFields.archive(record)
        let restored = CloudSyncSystemFields.record(from: data)
        XCTAssertEqual(restored?.recordID, record.recordID)
        XCTAssertEqual(restored?.recordType, CloudSyncSchema.recordType)
    }

    private func populatedRecord(
        schema: CloudSyncSchemaDescriptor,
        name: String
    ) -> CKRecord {
        let record = CKRecord(
            recordType: schema.recordType,
            recordID: schema.recordID(forRecordName: name)
        )
        SyncUpload(
            recordName: name,
            value: Data([1, 2, 3]),
            editedAt: 1,
            systemFields: nil
        ).populate(record, schema: schema)
        return record
    }
}
