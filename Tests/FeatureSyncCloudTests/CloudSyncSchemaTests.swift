import XCTest
import CloudKit
@testable import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncSchemaTests: XCTestCase {

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
}
