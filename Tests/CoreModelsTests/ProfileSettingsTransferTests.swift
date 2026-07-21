import XCTest
@testable import CoreModels

final class ProfileSettingsTransferTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileSettingsTransferTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testCaptureThenApplyRoundTripsAcrossStores() {
        let source = makeDefaults()
        // Seed a couple of transferable settings for the default profile (nil ns)
        // using representative value types (Data + primitives).
        source.set(Data([1, 2, 3]), forKey: "com.plozz.playbackSettings")
        source.set(true, forKey: "musicLyricsEnabled")
        // A non-transferable, device-local key that must NOT travel.
        source.set("sidebar", forKey: "navigationStyle")

        let entries = ProfileSettingsTransfer.capture(namespace: nil, defaults: source)
        XCTAssertNotNil(entries["com.plozz.playbackSettings"])
        XCTAssertNotNil(entries["musicLyricsEnabled"])
        XCTAssertNil(entries["navigationStyle"], "device-local settings must not be captured")

        let target = makeDefaults()
        ProfileSettingsTransfer.apply(entries, namespace: nil, defaults: target)
        XCTAssertEqual(target.data(forKey: "com.plozz.playbackSettings"), Data([1, 2, 3]))
        XCTAssertEqual(target.bool(forKey: "musicLyricsEnabled"), true)
        XCTAssertNil(target.string(forKey: "navigationStyle"))
    }

    func testNamespacedProfileKeysAreIsolated() {
        let source = makeDefaults()
        source.set(Data([9]), forKey: SettingsKey.scoped("com.plozz.appTheme", namespace: "kid"))

        let entries = ProfileSettingsTransfer.capture(namespace: "kid", defaults: source)
        XCTAssertEqual(entries["com.plozz.appTheme"], try? PropertyListSerialization.data(
            fromPropertyList: [Data([9])], format: .binary, options: 0
        ))

        let target = makeDefaults()
        ProfileSettingsTransfer.apply(entries, namespace: "kid", defaults: target)
        XCTAssertEqual(target.data(forKey: SettingsKey.scoped("com.plozz.appTheme", namespace: "kid")), Data([9]))
        // The default-namespace key stays untouched.
        XCTAssertNil(target.data(forKey: "com.plozz.appTheme"))
    }

    func testSnapshotSurvivesJSONRoundTrip() throws {
        let snap = ProfileSettingsSnapshot(profileID: "p1", entries: ["com.plozz.cardStyle": Data([7, 7])])
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(ProfileSettingsSnapshot.self, from: data), snap)
    }
}
