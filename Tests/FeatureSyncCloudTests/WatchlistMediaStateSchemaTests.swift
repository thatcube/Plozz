import XCTest
import CoreModels
@testable import FeatureSyncCloud

final class WatchlistMediaStateSchemaTests: XCTestCase {
    func testWatchlistRecordUsesOnlyMediaStateV1Schema() {
        let name = WatchlistMediaStateRecordKey(
            profileID: "p",
            aliasID: MediaAliasID()
        ).recordName

        XCTAssertEqual(
            CloudSyncSchemaDescriptor.mediaStateV1.kind(
                forRecordName: name
            ),
            "watchlist"
        )
        XCTAssertNotEqual(
            CloudSyncSchemaDescriptor.mediaStateV1.zoneName,
            CloudSyncSchemaDescriptor.configV3.zoneName
        )
        XCTAssertNotEqual(
            CloudSyncSchemaDescriptor.mediaStateV1.recordType,
            CloudSyncSchemaDescriptor.configV3.recordType
        )
    }
}
