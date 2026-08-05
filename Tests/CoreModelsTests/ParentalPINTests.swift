import XCTest
@testable import CoreModels

/// The rules that decide whether a Kids Profile is curation or enforcement.
///
/// These are the invariants every screen depends on, so they're pinned here
/// rather than re-derived per surface — a new settings page that forgets one
/// would otherwise quietly reopen an escalation route.
@MainActor
final class ParentalPINTests: XCTestCase {

    /// Lower rounds keep the suite fast; the derivation is identical either way.
    private let fastIterations = 64

    private func makeDefaults() -> UserDefaults {
        let suite = "ParentalPINTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A household with one grown-up and one Kids Profile, active as the kid.
    private func makeHousehold(
        defaults: UserDefaults? = nil
    ) -> (model: ProfilesModel, adult: Profile, kid: Profile) {
        let model = ProfilesModel(store: ProfileStore(defaults: defaults ?? makeDefaults()))
        let adult = model.profiles[0]
        let kid = model.add(name: "Kid", isKidsProfile: true)
        model.select(kid.id)
        return (model, adult, kid)
    }

    // MARK: The PIN itself

    func testVerifiesTheCorrectPIN() {
        let pin = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        XCTAssertEqual(pin?.matches(pin: "4821"), true)
    }

    func testRejectsTheWrongPIN() {
        let pin = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        XCTAssertEqual(pin?.matches(pin: "4822"), false)
    }

    func testRejectsMalformedPINs() {
        let pin = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        XCTAssertEqual(pin?.matches(pin: "482"), false)
        XCTAssertEqual(pin?.matches(pin: ""), false)
        XCTAssertNil(ParentalPIN.make(pin: "12a4", iterations: fastIterations))
        XCTAssertNil(ParentalPIN.make(pin: "12345", iterations: fastIterations))
    }

    /// Inspects the ENCODED form, which is what actually reaches disk and
    /// CloudKit. Substring checks on random Base64 are probabilistic and would
    /// pass even if the PIN were stored under another key.
    func testTheEncodedPINCarriesNoDigits() throws {
        let pin = try XCTUnwrap(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(pin), encoding: .utf8))
        XCTAssertFalse(json.contains("4821"))
        XCTAssertEqual(Set(["salt", "verifier", "iterations"]).isSubset(of: fieldNames(in: json)), true)
        // Any field beyond those three is a new place the PIN could leak.
        XCTAssertEqual(fieldNames(in: json).count, 3)
    }

    private func fieldNames(in json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(object.keys)
    }

    func testTwoPINsWithTheSameValueGetDifferentVerifiers() {
        let a = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        let b = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        XCTAssertNotEqual(a?.salt, b?.salt)
        XCTAssertNotEqual(a?.verifier, b?.verifier)
    }

    // MARK: Curation vs enforcement

    func testKidsRestrictNothingWithoutAPIN() {
        let (model, _, kid) = makeHousehold()
        XCTAssertFalse(model.enforcesKidsRestrictions)
        XCTAssertTrue(model.canEditRestrictedSettings(of: kid))
    }

    func testKidsAreEnforcedOnceAPINExists() {
        let (model, _, kid) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertTrue(model.enforcesKidsRestrictions)
        XCTAssertFalse(model.canEditRestrictedSettings(of: kid))
    }

    /// A grown-up profile is never restricted, PIN or no PIN.
    func testGrownUpProfilesAreNeverRestricted() {
        let (model, adult, _) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertTrue(model.canEditRestrictedSettings(of: adult))
    }

    /// Clearing the PIN must not silently turn Kids Profiles off.
    func testClearingThePINLeavesKidsProfilesOn() {
        let (model, _, _) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        model.setParentalPIN(nil)
        XCTAssertFalse(model.enforcesKidsRestrictions)
        XCTAssertTrue(model.profiles.contains { $0.isKids })
    }

    // MARK: Switching

    func testLeavingAKidsProfileNeedsThePIN() {
        let (model, adult, kid) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertTrue(model.requiresParentalPIN(switchingFrom: kid, to: adult))
    }

    /// The adults shouldn't pay for the child's restrictions in daily use.
    func testSwitchingBetweenGrownUpProfilesIsFree() {
        let (model, adult, _) = makeHousehold()
        let second = model.add(name: "Other grown-up")
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertFalse(model.requiresParentalPIN(switchingFrom: adult, to: second))
    }

    /// Handing the TV to a second child shouldn't need a grown-up.
    func testSwitchingBetweenKidsProfilesIsFree() {
        let (model, _, kid) = makeHousehold()
        let second = model.add(name: "Kid two", isKidsProfile: true)
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertFalse(model.requiresParentalPIN(switchingFrom: kid, to: second))
    }

    func testSwitchingIsFreeWithoutAPIN() {
        let (model, adult, kid) = makeHousehold()
        XCTAssertFalse(model.requiresParentalPIN(switchingFrom: kid, to: adult))
    }

    // MARK: Verification through the model

    func testModelVerifiesThePIN() {
        let (model, _, _) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertTrue(model.matchesParentalPIN("4821"))
        XCTAssertFalse(model.matchesParentalPIN("0000"))
    }

    /// "No PIN set" must never read as "every PIN works".
    func testNoPINMatchesNothing() {
        let (model, _, _) = makeHousehold()
        XCTAssertFalse(model.matchesParentalPIN("4821"))
        XCTAssertFalse(model.matchesParentalPIN(""))
    }

    // MARK: Persistence

    func testThePINSurvivesAReload() {
        let defaults = makeDefaults()
        let (first, _, _) = makeHousehold(defaults: defaults)
        first.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))

        let second = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(second.enforcesKidsRestrictions)
        XCTAssertTrue(second.matchesParentalPIN("4821"))
    }
}

/// The Parental PIN rides the household's first profile record so it syncs.
/// These pin the conflict rules, because a parental control that a stale device
/// can erase is worse than none — you'd believe it was on.
@MainActor
final class ParentalPINSyncTests: XCTestCase {

    private let fastIterations = 64

    private func makeDefaults() -> UserDefaults {
        let suite = "ParentalPINSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeModel() -> ProfilesModel {
        ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
    }

    func testThePINIsCarriedOnTheFirstProfile() {
        let model = makeModel()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        XCTAssertNotNil(model.profiles.first?.parentalPIN)
    }

    /// The whole point of moving it off device-local storage.
    func testThePINTravelsInTheSyncDTO() {
        let model = makeModel()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        let dto = ProfileSyncDTO(profile: model.profiles[0])
        XCTAssertNotNil(dto.parentalPIN)
        XCTAssertEqual(dto.parentalPIN?.matches(pin: "4821"), true)
    }

    func testAnIncomingPINIsAdopted() {
        let model = makeModel()
        var remote = model.profiles[0]
        remote.replaceParentalPIN(with: ParentalPIN.make(pin: "4821", iterations: fastIterations))

        let merged = ProfileSyncDTO(profile: remote).merged(into: model.profiles[0])
        XCTAssertEqual(merged.parentalPIN?.matches(pin: "4821"), true)
    }

    /// The failure that erased profile locks once already: an unrelated rename
    /// syncing from a device that never saw the PIN.
    func testAStaleRecordCannotEraseThePIN() {
        let model = makeModel()
        let stale = model.profiles[0]

        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        let current = model.profiles[0]

        var renamed = stale
        renamed.name = "Renamed elsewhere"
        let merged = ProfileSyncDTO(profile: renamed).merged(into: current)

        XCTAssertEqual(merged.name, "Renamed elsewhere")
        XCTAssertEqual(merged.parentalPIN?.matches(pin: "4821"), true, "A stale record must not clear the PIN")
    }

    /// Removal has to survive too, or "Remove Parental PIN" would silently undo
    /// itself on the next sync.
    func testARemovalWinsOverAnOlderPIN() {
        let model = makeModel()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        let withPIN = model.profiles[0]

        model.setParentalPIN(nil)
        let removed = model.profiles[0]

        let merged = ProfileSyncDTO(profile: removed).merged(into: withPIN)
        XCTAssertNil(merged.parentalPIN)
    }

    func testANewerPINReplacesAnOlderOne() {
        let model = makeModel()
        model.setParentalPIN(ParentalPIN.make(pin: "1111", iterations: fastIterations))
        let older = model.profiles[0]

        model.setParentalPIN(ParentalPIN.make(pin: "2222", iterations: fastIterations))
        let newer = model.profiles[0]

        let merged = ProfileSyncDTO(profile: newer).merged(into: older)
        XCTAssertEqual(merged.parentalPIN?.matches(pin: "2222"), true)
        XCTAssertEqual(merged.parentalPIN?.matches(pin: "1111"), false)
    }

    /// A device arriving with no knowledge of the field mustn't clear it.
    func testALegacyPeerWithoutRevisionsCannotClearThePIN() {
        let model = makeModel()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        let current = model.profiles[0]

        var legacy = ProfileSyncDTO(profile: current)
        legacy.parentalPIN = nil
        legacy.parentalPINRevision = nil

        XCTAssertEqual(legacy.merged(into: current).parentalPIN?.matches(pin: "4821"), true)
    }

    /// A profile record from another device shouldn't drag its own copy of the
    /// PIN onto a non-anchor profile and create two sources of truth.
    func testTheModelReadsThePINFromTheFirstProfileOnly() {
        let model = makeModel()
        let second = model.add(name: "Second")
        var polluted = second
        polluted.replaceParentalPIN(with: ParentalPIN.make(pin: "9999", iterations: fastIterations))
        model.update(polluted)

        XCTAssertFalse(model.enforcesKidsRestrictions, "Only the first profile anchors the PIN")
        XCTAssertFalse(model.matchesParentalPIN("9999"))
    }
}

/// The rules that stop a child escaping their own profile, and stop a stale peer
/// quietly lifting the restriction. These are the security-relevant invariants,
/// so they're pinned separately from the UI.
@MainActor
final class ParentalEnforcementTests: XCTestCase {

    private let fastIterations = 64

    private func makeDefaults() -> UserDefaults {
        let suite = "ParentalEnforcementTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeHousehold(
        defaults: UserDefaults? = nil
    ) -> (model: ProfilesModel, adult: Profile, kid: Profile) {
        let model = ProfilesModel(store: ProfileStore(defaults: defaults ?? makeDefaults()))
        let adult = model.profiles[0]
        let kid = model.add(name: "Kid", isKidsProfile: true)
        return (model, adult, kid)
    }

    // MARK: Management gate

    /// Creating a profile SWITCHES into it, so an ungated "Add Profile" inside a
    /// Kids Profile is a complete bypass of the switch gate.
    func testManagementIsWithheldInsideAnEnforcedKidsProfile() {
        let (model, _, kid) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        model.select(kid.id)
        XCTAssertTrue(model.managementRequiresParentalPIN)
    }

    func testManagementIsAllowedWithoutAPIN() {
        let (model, _, kid) = makeHousehold()
        model.select(kid.id)
        XCTAssertFalse(model.managementRequiresParentalPIN)
    }

    func testManagementIsAllowedFromAGrownUpProfile() {
        let (model, adult, _) = makeHousehold()
        model.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))
        model.select(adult.id)
        XCTAssertFalse(model.managementRequiresParentalPIN)
    }

    // MARK: The Kids flag must survive a stale peer

    /// The flag is what makes the gate apply at all, so clobbering it doesn't
    /// lose a preference — it un-restricts the child everywhere.
    func testAStaleRecordCannotClearTheKidsFlag() {
        let (model, _, kid) = makeHousehold()
        let stale = kid            // captured before it became a Kids Profile
        var nowKids = kid
        nowKids.isKids = true
        model.update(nowKids)

        var renamedElsewhere = stale
        renamedElsewhere.name = "Renamed"
        renamedElsewhere.isKidsProfile = nil

        let merged = ProfileSyncDTO(profile: renamedElsewhere).merged(into: nowKids)
        XCTAssertEqual(merged.name, "Renamed")
        XCTAssertTrue(merged.isKids, "A stale record must not lift the restriction")
    }

    /// Turning Kids off deliberately still has to win over an older record.
    func testADeliberateKidsRemovalWins() {
        let (model, _, kid) = makeHousehold()
        var nowKids = kid
        nowKids.isKids = true
        model.update(nowKids)

        var lifted = nowKids
        lifted.isKids = false

        let merged = ProfileSyncDTO(profile: lifted).merged(into: nowKids)
        XCTAssertFalse(merged.isKids)
    }

    // MARK: Migration

    /// A PIN the user deliberately removed must not come back when a device that
    /// still holds the old device-local copy relaunches.
    func testMigrationDoesNotResurrectARemovedPIN() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        // A build that kept the PIN on the device.
        store.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))

        // This run migrates it onto the anchor…
        let first = ProfilesModel(store: store)
        XCTAssertTrue(first.enforcesKidsRestrictions)
        // …and the user then removes it.
        first.setParentalPIN(nil)
        XCTAssertFalse(first.enforcesKidsRestrictions)

        // A later launch must respect the removal.
        let second = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertFalse(second.enforcesKidsRestrictions, "A removed PIN must stay removed")
    }

    func testMigrationMovesADeviceLocalPINOntoTheSyncedAnchor() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        store.setParentalPIN(ParentalPIN.make(pin: "4821", iterations: fastIterations))

        let model = ProfilesModel(store: store)
        XCTAssertNotNil(model.profiles.first?.parentalPIN, "It must ride the profile so it syncs")
        XCTAssertNil(store.parentalPIN(), "And the device-local copy is retired")
        XCTAssertTrue(model.matchesParentalPIN("4821"))
    }
}
