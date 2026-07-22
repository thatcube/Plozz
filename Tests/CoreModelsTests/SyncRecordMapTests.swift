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

    // MARK: C1 — no credential in a synced avatar URL; local token preserved

    func testProfileDTOStripsTokenFromAvatarURL() {
        let p = Profile(id: "P1", name: "Kid", avatarSymbol: "star.fill", colorIndex: 1,
                        avatarImageURL: "https://media.example.com/Users/u/Images/Primary?api_key=SECRETTOKEN")
        let dto = ProfileSyncDTO(profile: p)
        let json = String(decoding: CanonicalJSON.encode(dto)!, as: UTF8.self)
        XCTAssertFalse(json.contains("SECRETTOKEN"), "avatar token leaked into synced DTO")
        XCTAssertFalse(json.lowercased().contains("api_key"))
    }

    /// Applying a stripped DTO must preserve THIS device's local tokenized URL (so the
    /// image keeps rendering) while capture re-strips it — keeping capture==apply.
    func testMergePreservesLocalTokenWhileCaptureStaysStripped() {
        let tokenized = "https://media.example.com/Users/u/Images/Primary?api_key=SECRETTOKEN"
        let stripped = SyncURLSanitizer.sanitize(string: tokenized)
        var local = Profile(id: "P1", name: "Kid", avatarSymbol: "star.fill", colorIndex: 1,
                            avatarImageURL: tokenized)
        local.plexHomeUserID = "home-1"

        // Peer sends the (already-stripped) DTO for the same resource.
        var remote = local
        remote.avatarImageURL = stripped
        remote.plexHomeUserID = nil
        let dto = ProfileSyncDTO(profile: remote)

        let applied = dto.merged(into: local)
        XCTAssertEqual(applied.avatarImageURL, tokenized, "local token must be preserved for rendering")
        XCTAssertEqual(applied.plexHomeUserID, "home-1", "device-local field lost")

        // Re-capture is byte-identical to what we received (no clobber loop).
        let recaptured = CanonicalJSON.encode(ProfileSyncDTO(profile: applied))!
        XCTAssertEqual(recaptured, CanonicalJSON.encode(dto)!, "capture(apply) != x with tokenized local avatar")
    }

    func testDescriptorStripsTokenAndPreservesSemantics() {
        // A descriptor carrying a tokenized avatar URL (as a signed-in Jellyfin
        // account would produce) must never serialize the token.
        let tokenized = SyncedAccountDescriptor(
            id: "A1", provider: .jellyfin, serverID: "s1", serverName: "Home",
            userID: "u1", userName: "User",
            avatarURL: URL(string: "http://192.168.1.2:8096/Users/u1/Images/Primary?api_key=SECRETTOKEN"),
            candidateBaseURLs: [URL(string: "http://192.168.1.2:8096?X-Plex-Token=T0K3N")!])
        let clean = tokenized.sanitizingURLs()
        let json = String(decoding: CanonicalJSON.encode(clean)!, as: UTF8.self)
        XCTAssertFalse(json.contains("SECRETTOKEN"), "descriptor avatar token leaked")
        XCTAssertFalse(json.contains("T0K3N"), "descriptor candidate-URL token leaked")
        // Semantic identity intact.
        XCTAssertEqual(clean.serverName, "Home")
        XCTAssertEqual(clean.userID, "u1")
    }

    func testDescriptorSemanticEqualityIgnoresCandidateURLs() {
        let base = SyncedAccountDescriptor(
            id: "A1", provider: .jellyfin, serverID: "s1", serverName: "Home",
            userID: "u1", userName: "User",
            candidateBaseURLs: [URL(string: "http://10.0.0.5:8096")!])
        var other = base
        other.candidateBaseURLs = [URL(string: "http://192.168.1.9:8096")!]
        other.recordVersion = 99
        XCTAssertTrue(base.semanticallyEqualForSync(to: other),
                      "per-device reachable URLs / recordVersion must not count as a semantic change")
        var renamed = base
        renamed.serverName = "Renamed"
        XCTAssertFalse(base.semanticallyEqualForSync(to: renamed))
    }
}
