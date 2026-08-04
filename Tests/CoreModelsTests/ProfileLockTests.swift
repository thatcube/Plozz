import XCTest
@testable import CoreModels

final class ProfileLockTests: XCTestCase {

    /// Lower rounds keep the suite fast; the derivation is identical either way.
    private let fastIterations = 64

    // MARK: PIN validation

    func testAcceptsExactlyFourASCIIDigits() {
        XCTAssertTrue(ProfileLock.isValidPIN("0000"))
        XCTAssertTrue(ProfileLock.isValidPIN("9184"))
    }

    func testRejectsWrongLength() {
        XCTAssertFalse(ProfileLock.isValidPIN(""))
        XCTAssertFalse(ProfileLock.isValidPIN("123"))
        XCTAssertFalse(ProfileLock.isValidPIN("12345"))
    }

    /// Non-ASCII digits would hash to a verifier the user can't reproduce from a
    /// normal keypad, silently locking them out of their own profile.
    func testRejectsNonASCIIDigitsAndLetters() {
        XCTAssertFalse(ProfileLock.isValidPIN("12a4"))
        XCTAssertFalse(ProfileLock.isValidPIN("١٢٣٤"))
        XCTAssertFalse(ProfileLock.isValidPIN("12 4"))
    }

    // MARK: Verification

    func testCorrectPINMatches() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        XCTAssertTrue(lock.matches(pin: "4821"))
    }

    func testWrongPINDoesNotMatch() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        XCTAssertFalse(lock.matches(pin: "4822"))
        XCTAssertFalse(lock.matches(pin: "1284"))
    }

    func testMalformedPINDoesNotMatch() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        XCTAssertFalse(lock.matches(pin: "482"))
        XCTAssertFalse(lock.matches(pin: ""))
    }

    func testMakeRejectsInvalidPIN() {
        XCTAssertNil(ProfileLock.make(pin: "abc", iterations: fastIterations))
        XCTAssertNil(ProfileLock.make(pin: "12345", iterations: fastIterations))
    }

    // MARK: Storage shape

    /// The whole point of the verifier: reading the stored profile must not hand
    /// over the PIN. Guards against someone "simplifying" this to a plain field.
    func testStoredFieldsNeverContainThePIN() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        XCTAssertFalse(lock.verifier.contains("4821"))
        XCTAssertFalse(lock.salt.contains("4821"))
    }

    /// Two locks with the same PIN must not share a verifier, or one lookup table
    /// would open every profile in the household at once.
    func testSamePINProducesDifferentVerifiersAcrossLocks() throws {
        let a = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        let b = try XCTUnwrap(ProfileLock.make(pin: "4821", iterations: fastIterations))
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.verifier, b.verifier)
        // ...but each still opens with the PIN it was made from.
        XCTAssertTrue(a.matches(pin: "4821"))
        XCTAssertTrue(b.matches(pin: "4821"))
    }

    /// The iteration count is persisted so it can be raised later without
    /// invalidating locks already in the wild — verify an existing lock still
    /// opens using its own stored count rather than the current default.
    func testVerificationUsesTheLocksOwnIterationCount() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "1357", iterations: fastIterations))
        XCTAssertEqual(lock.iterations, fastIterations)
        XCTAssertNotEqual(lock.iterations, ProfileLock.defaultIterations)
        XCTAssertTrue(lock.matches(pin: "1357"))
    }

    // MARK: Codable / migration

    func testRoundTripsThroughJSON() throws {
        let lock = try XCTUnwrap(ProfileLock.make(pin: "2468", matchesPlexPIN: true, iterations: fastIterations))
        let data = try JSONEncoder().encode(lock)
        let decoded = try JSONDecoder().decode(ProfileLock.self, from: data)
        XCTAssertEqual(decoded, lock)
        XCTAssertTrue(decoded.matches(pin: "2468"))
        XCTAssertTrue(decoded.matchesPlexPIN)
    }

    /// Profiles written before this field existed must keep decoding, unlocked.
    func testProfileWithoutLockDecodesAsUnlocked() throws {
        let legacy = #"{"id":"p1","name":"Kid","avatarSymbol":"star","colorIndex":0,"createdAt":0}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertNil(profile.lock)
        XCTAssertFalse(profile.isLocked)
    }

    func testProfileWithLockReportsLocked() throws {
        var profile = Profile(name: "Brando")
        XCTAssertFalse(profile.isLocked)
        profile.lock = ProfileLock.make(pin: "1111", iterations: fastIterations)
        XCTAssertTrue(profile.isLocked)
    }

    // MARK: Sync

    /// A lock that stayed on one device wouldn't be a lock — the same profile is
    /// one tap away on the iPhone. So it has to survive the sync DTO round trip.
    func testLockSurvivesTheProfileSyncDTO() throws {
        var profile = Profile(name: "Brando")
        profile.lock = ProfileLock.make(pin: "5309", iterations: fastIterations)

        let restored = ProfileSyncDTO(profile: profile).makeProfile()
        XCTAssertEqual(restored.lock, profile.lock)
        XCTAssertTrue(try XCTUnwrap(restored.lock).matches(pin: "5309"))
    }

    func testMergingASyncedLockOntoALocalProfile() throws {
        var remote = Profile(id: "p1", name: "Brando")
        remote.lock = ProfileLock.make(pin: "5309", iterations: fastIterations)
        // Local copy has device-local Plex state the merge must preserve.
        var local = Profile(id: "p1", name: "Brando", plexHomeUserID: "home-1")

        local = ProfileSyncDTO(profile: remote).merged(into: local)
        XCTAssertEqual(local.lock, remote.lock)
        XCTAssertEqual(local.plexHomeUserID, "home-1")
    }

    /// Removing a lock on one device must clear it everywhere, not be ignored as
    /// "no value sent".
    func testClearingALockPropagatesThroughTheDTO() throws {
        var local = Profile(id: "p1", name: "Brando")
        local.lock = ProfileLock.make(pin: "5309", iterations: fastIterations)

        let remoteWithoutLock = Profile(id: "p1", name: "Brando")
        local = ProfileSyncDTO(profile: remoteWithoutLock).merged(into: local)
        XCTAssertNil(local.lock)
    }
}

/// The restriction half: a Kids Profile hides the shared settings so a child in
/// their own (deliberately unlocked) profile can't route around the lock on the
/// grown-ups' profiles by deleting them, removing servers, or signing out.
final class KidsProfileTests: XCTestCase {

    func testDefaultsToUnrestricted() {
        let profile = Profile(name: "Brando")
        XCTAssertFalse(profile.isKids)
        XCTAssertNil(profile.isKidsProfile)
    }

    func testSettingAndClearingTheFlag() {
        var profile = Profile(name: "Kid")
        profile.isKids = true
        XCTAssertTrue(profile.isKids)
        profile.isKids = false
        XCTAssertFalse(profile.isKids)
    }

    /// Profiles written before this field existed must keep decoding, unrestricted.
    func testLegacyProfileDecodesAsUnrestricted() throws {
        let legacy = #"{"id":"p1","name":"Kid","avatarSymbol":"star","colorIndex":0,"createdAt":0}"#
        let profile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertFalse(profile.isKids)
    }

    /// Clearing must write *absence*, not `false` — an older peer omits the key
    /// entirely, and the sync layer requires capture(apply(x)) to be byte-stable.
    func testClearedFlagIsOmittedFromTheEncodingRatherThanWrittenAsFalse() throws {
        var profile = Profile(name: "Kid")
        profile.isKids = true
        profile.isKids = false

        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        XCTAssertFalse(json.contains("isKidsProfile"), json)
    }

    func testFlagSurvivesTheSyncRoundTrip() {
        var profile = Profile(name: "Kid")
        profile.isKids = true

        let restored = ProfileSyncDTO(profile: profile).makeProfile()
        XCTAssertTrue(restored.isKids, "a restriction that stayed on one device wouldn't restrict anything")
    }

    func testMergingPreservesDeviceLocalStateWhileApplyingTheFlag() {
        var remote = Profile(id: "p1", name: "Kid")
        remote.isKids = true
        var local = Profile(id: "p1", name: "Kid", plexHomeUserID: "home-1")

        local = ProfileSyncDTO(profile: remote).merged(into: local)
        XCTAssertTrue(local.isKids)
        XCTAssertEqual(local.plexHomeUserID, "home-1")
    }

    /// Lifting the restriction on one device must lift it everywhere.
    func testClearingTheFlagPropagates() {
        var local = Profile(id: "p1", name: "Kid")
        local.isKids = true

        let remoteUnrestricted = Profile(id: "p1", name: "Kid")
        local = ProfileSyncDTO(profile: remoteUnrestricted).merged(into: local)
        XCTAssertFalse(local.isKids)
    }

    /// The two features are independent: a Kids Profile is normally left UNLOCKED
    /// (the child has to be able to get in) while the grown-ups' profiles carry
    /// the locks.
    func testRestrictionAndLockAreIndependent() {
        var kid = Profile(name: "Kid")
        kid.isKids = true
        XCTAssertTrue(kid.isKids)
        XCTAssertFalse(kid.isLocked, "a kids profile is normally left open")

        var adult = Profile(name: "Brando")
        adult.lock = ProfileLock.make(pin: "4821", iterations: 64)
        XCTAssertTrue(adult.isLocked)
        XCTAssertFalse(adult.isKids)
    }
}
