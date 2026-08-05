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

    func testNeverStoresTheRawPIN() {
        let pin = ParentalPIN.make(pin: "4821", iterations: fastIterations)
        XCTAssertFalse(pin?.verifier.contains("4821") ?? true)
        XCTAssertFalse(pin?.salt.contains("4821") ?? true)
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
