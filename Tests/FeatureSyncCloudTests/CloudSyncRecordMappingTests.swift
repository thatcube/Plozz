import XCTest
import CloudKit
@testable import CoreModels
@testable import FeatureSyncCloud

final class CloudSyncRecordMappingTests: XCTestCase {

    /// A CloudSyncRecord survives a round-trip through a CKRecord (field encode ->
    /// decode) unchanged. Guards the wire mapping the CKSyncEngine batch relies on.
    func testCKRecordRoundTrip() throws {
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let original = CloudSyncRecord(kind: .profile, id: "p1", version: 7, payload: payload)

        let ck = CKRecord(recordType: CloudSyncSchema.recordType,
                          recordID: CloudSyncSchema.recordID(forRecordName: original.recordName))
        original.populate(ck)

        XCTAssertEqual(ck.recordType, CloudSyncSchema.recordType)
        XCTAssertEqual(ck.recordID.recordName, "profile:p1")
        XCTAssertEqual(ck.recordID.zoneID.zoneName, CloudSyncSchema.zoneName)

        let decoded = try XCTUnwrap(CloudSyncRecord(ckRecord: ck))
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsWrongRecordType() {
        let ck = CKRecord(recordType: "SomethingElse",
                          recordID: CloudSyncSchema.recordID(forRecordName: "account:A"))
        ck["kind"] = "account" as CKRecordValue
        ck["entityID"] = "A" as CKRecordValue
        ck["version"] = Int64(1) as CKRecordValue
        ck["payload"] = Data() as CKRecordValue
        XCTAssertNil(CloudSyncRecord(ckRecord: ck), "records of an unexpected type must not decode")
    }

    func testDecodeRejectsMissingFields() {
        let ck = CKRecord(recordType: CloudSyncSchema.recordType,
                          recordID: CloudSyncSchema.recordID(forRecordName: "account:A"))
        // Missing kind/version/payload.
        ck["entityID"] = "A" as CKRecordValue
        XCTAssertNil(CloudSyncRecord(ckRecord: ck))
    }

    func testDecodeRejectsUnknownKind() {
        let ck = CKRecord(recordType: CloudSyncSchema.recordType,
                          recordID: CloudSyncSchema.recordID(forRecordName: "future:X"))
        ck["kind"] = "future" as CKRecordValue
        ck["entityID"] = "X" as CKRecordValue
        ck["version"] = Int64(1) as CKRecordValue
        ck["payload"] = Data() as CKRecordValue
        XCTAssertNil(CloudSyncRecord(ckRecord: ck), "a newer schema's kind must decode to nil, not crash")
    }
}
