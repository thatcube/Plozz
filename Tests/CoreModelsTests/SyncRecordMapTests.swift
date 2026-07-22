import XCTest
@testable import CoreModels

final class SyncRecordMapTests: XCTestCase {

    // MARK: Record key parsing / round-trip

    func testRecordKeyRoundTrip() {
        let cases: [SyncRecordKey] = [
            SyncRecordKey(kind: .descriptor, id: "acct-123"),
            SyncRecordKey(kind: .profile, id: "com.plozz.profile.default"),
            SyncRecordKey(kind: .membership, id: "P1"),
            SyncRecordKey(kind: .setting, id: "P1", subkey: "com.plozz.appTheme"),
            // A setting base key that itself contains dots must survive.
            SyncRecordKey(kind: .setting, id: "P1", subkey: "com.plozz.homeLayout.v2"),
        ]
        for key in cases {
            let parsed = SyncRecordKey.parse(key.recordName)
            XCTAssertEqual(parsed, key, "round-trip failed for \(key.recordName)")
        }
    }

    func testRecordKeyRejectsMalformed() {
        XCTAssertNil(SyncRecordKey.parse("bogus"))
        XCTAssertNil(SyncRecordKey.parse("unknownkind:1"))
        XCTAssertNil(SyncRecordKey.parse("setting:onlyid"))     // missing subkey
        XCTAssertNil(SyncRecordKey.parse("profile:a:b"))        // too many parts for non-setting
    }

    // MARK: ProfileSyncDTO — cosmetic-only, canonical, round-trips exactly

    func testProfileDTOExcludesDeviceLocalFields() {
        var p = Profile(name: "Kid", avatarSymbol: "star.fill", colorIndex: 3,
                        avatarEmoji: "🦊", avatarEmojiColorIndex: 7)
        // Set device-local fields that MUST NOT sync.
        p.linkedAccountID = "acct-9"
        p.plexHomeUserID = "home-1"
        p.plexHomeUserAccountID = "plex-acct"
        p.seerrUserID = 42
        let dto = ProfileSyncDTO(profile: p)
        let data = CanonicalJSON.encode(dto)!
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("linkedAccountID"))
        XCTAssertFalse(json.contains("plexHomeUser"))
        XCTAssertFalse(json.contains("seerr"))
        XCTAssertTrue(json.contains("Kid"))
    }

    func testProfileDTOCanonicalCaptureAfterApplyIsIdentity() {
        // The core invariant: canonicalCapture(exactApply(record)) == record.value.
        // Applying a DTO to an existing profile (preserving device-local fields) and
        // re-capturing must yield byte-identical canonical bytes.
        var local = Profile(id: "P1", name: "Old", avatarSymbol: "person.fill", colorIndex: 0)
        local.plexHomeUserID = "home-xyz"       // device-local, must be preserved + ignored
        local.seerrUserID = 5

        let incoming = ProfileSyncDTO(profile: Profile(
            id: "P1", name: "New Name", avatarSymbol: "star.fill", colorIndex: 4,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            avatarImageURL: "http://x/y.jpg", avatarEmoji: "🎉", avatarEmojiColorIndex: 2))
        let incomingBytes = CanonicalJSON.encode(incoming)!

        // Exact apply → merge into local (preserving device-local fields).
        let applied = incoming.merged(into: local)
        XCTAssertEqual(applied.plexHomeUserID, "home-xyz", "device-local field lost on apply")
        XCTAssertEqual(applied.seerrUserID, 5)

        // Re-capture the DTO from the applied profile → must equal what we received.
        let recaptured = CanonicalJSON.encode(ProfileSyncDTO(profile: applied))!
        XCTAssertEqual(recaptured, incomingBytes, "capture(apply(x)) != x — would clobber peers")
    }

    func testProfileDTOCanonicalIsStableAcrossReencodes() {
        let p = Profile(id: "P1", name: "Stable", avatarSymbol: "person.fill", colorIndex: 1,
                        createdAt: Date(timeIntervalSince1970: 12345), avatarEmoji: "😀")
        let a = CanonicalJSON.encode(ProfileSyncDTO(profile: p))!
        let b = CanonicalJSON.encode(ProfileSyncDTO(profile: p))!
        XCTAssertEqual(a, b, "canonical encoding is not deterministic")
        // Decodes back to an equal DTO.
        let decoded = CanonicalJSON.decode(ProfileSyncDTO.self, from: a)
        XCTAssertEqual(decoded, ProfileSyncDTO(profile: p))
    }

    func testMakeProfileFromDTO() {
        let dto = ProfileSyncDTO(profile: Profile(
            id: "P9", name: "Fresh", avatarSymbol: "bolt.fill", colorIndex: 2,
            createdAt: Date(timeIntervalSince1970: 42), avatarEmoji: "⚡️", avatarEmojiColorIndex: 3))
        let made = dto.makeProfile()
        XCTAssertEqual(made.id, "P9")
        XCTAssertEqual(made.name, "Fresh")
        XCTAssertEqual(made.avatarSymbol, "bolt.fill")
        XCTAssertEqual(made.colorIndex, 2)
        XCTAssertEqual(made.avatarEmoji, "⚡️")
        XCTAssertEqual(made.avatarEmojiColorIndex, 3)
        // Device-local fields default to nil.
        XCTAssertNil(made.plexHomeUserID)
        XCTAssertNil(made.seerrUserID)
    }
}
