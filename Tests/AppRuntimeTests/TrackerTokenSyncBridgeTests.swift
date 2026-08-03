import XCTest
import CoreModels
import CoreSecureStore
@testable import AppRuntime

/// The record name is the only part of a tracker sign-in that travels
/// unencrypted, so it must be derivable from non-secret identifiers and must
/// round-trip exactly.
final class TrackerTokenSyncBridgeTests: XCTestCase {
    func testRecordNameRoundTripsServiceAndAccount() {
        let account = SyncedTokenRegistry.Account(
            service: "com.plozz.app.tokens",
            account: "simkl.oauth.594FF694-6097-4793-9BF7-4F5900DD0C25"
        )
        let name = TrackerTokenSyncBridge.recordName(for: account)
        XCTAssertEqual(TrackerTokenSyncBridge.account(fromRecordName: name), account)
    }

    func testRecordNameCarriesNoTokenMaterial() {
        let account = SyncedTokenRegistry.Account(
            service: "com.plozz.app.tokens",
            account: "trakt.oauth.profile"
        )
        let name = TrackerTokenSyncBridge.recordName(for: account)
        XCTAssertTrue(name.contains("trakt.oauth.profile"))
        XCTAssertTrue(name.hasPrefix("trackerToken:"))
    }

    func testForeignRecordNamesAreIgnored() {
        for name in [
            "mediaState:something",
            "trackerToken:",
            "trackerToken:onlyservice",
            "trackerToken:|account",
            "trackerToken:service|"
        ] {
            XCTAssertNil(
                TrackerTokenSyncBridge.account(fromRecordName: name),
                "\(name) must not decode as a tracker account"
            )
        }
    }

    /// A device that has never signed in must not publish an empty set and
    /// delete a sign-in another device made.
    func testCaptureKeepsRecordsItKnowsNothingAbout() {
        let known = TrackerTokenSyncBridge.recordName(
            for: .init(service: "com.plozz.app.tokens", account: "simkl.oauth.p")
        )
        let payload = Data("{}".utf8)
        let captured = TrackerTokenSyncBridge.capture(fallback: [known: payload])
        XCTAssertEqual(
            captured[known],
            payload,
            "an unknown account must be preserved, not treated as removed"
        )
    }

    func testCaptureDropsUnrelatedFallbackRecords() {
        let foreign: SyncRecordID = "mediaState:abc"
        let captured = TrackerTokenSyncBridge.capture(
            fallback: [foreign: Data("x".utf8)]
        )
        XCTAssertNil(
            captured[foreign],
            "this channel must only ever publish tracker records"
        )
    }

    /// Applying changes that aren't tracker records must be a no-op rather than
    /// touching the Keychain.
    func testApplyIgnoresForeignRecords() {
        let touched = TrackerTokenSyncBridge.apply([
            "mediaState:abc": Data("x".utf8),
            "trackerToken:bad": nil
        ])
        XCTAssertTrue(touched.isEmpty)
    }
}
