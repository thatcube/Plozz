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

    /// The regression that caused the endless republish storm: a JSON `Data` blob
    /// whose object key order differs (as `JSONEncoder` emits `Dictionary`
    /// properties in non-deterministic order on each re-encode) MUST capture to the
    /// SAME bytes, or the sync mirror sees a phantom change and re-stamps forever.
    func testCaptureIsByteStableAcrossJSONKeyOrder() {
        // Two encodings of the same logical object, keys in different order.
        let orderA = Data(#"{"b":2,"a":1,"c":3}"#.utf8)
        let orderB = Data(#"{"c":3,"a":1,"b":2}"#.utf8)

        let dA = makeDefaults(); dA.set(orderA, forKey: "com.plozz.playbackSettings")
        let dB = makeDefaults(); dB.set(orderB, forKey: "com.plozz.playbackSettings")

        let capA = ProfileSettingsTransfer.capture(namespace: nil, defaults: dA)
        let capB = ProfileSettingsTransfer.capture(namespace: nil, defaults: dB)

        XCTAssertEqual(capA["com.plozz.playbackSettings"],
                       capB["com.plozz.playbackSettings"],
                       "capture must be byte-stable regardless of JSON key ordering")
    }

    /// Capturing the SAME value twice is idempotent (no phantom changes), and a
    /// non-JSON `Data` blob is preserved verbatim (canonicalization only touches
    /// values that actually parse as JSON).
    func testCaptureIdempotentAndPreservesNonJSONData() {
        let d = makeDefaults()
        d.set(Data(#"{"z":1,"a":2}"#.utf8), forKey: "com.plozz.subtitleStyle")
        d.set(Data([0xFF, 0x00, 0x42]), forKey: "com.plozz.appTheme") // not JSON

        let first = ProfileSettingsTransfer.capture(namespace: nil, defaults: d)
        let second = ProfileSettingsTransfer.capture(namespace: nil, defaults: d)
        XCTAssertEqual(first, second, "capture must be deterministic for unchanged input")

        // Non-JSON blob round-trips byte-for-byte through apply.
        let target = makeDefaults()
        ProfileSettingsTransfer.apply(first, namespace: nil, defaults: target)
        XCTAssertEqual(target.data(forKey: "com.plozz.appTheme"), Data([0xFF, 0x00, 0x42]))
    }
}
