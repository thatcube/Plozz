import XCTest
@testable import CoreModels

/// Covers the first-run profile-seed building blocks: the household-wide
/// "setup complete" gate and seeding the default profile's identity from the
/// first sign-in. The state-machine detour itself is covered in FeatureAuthTests.
final class FirstRunProfileSeedStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "FirstRunProfileSeedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFirstRunSetupFlagDefaultsFalseAndPersists() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        XCTAssertFalse(store.firstRunProfileSetupComplete(),
                       "A brand-new install must report first-run setup as incomplete")
        store.setFirstRunProfileSetupComplete(true)
        XCTAssertTrue(store.firstRunProfileSetupComplete())
        // A fresh store over the same backing must still see it done, so
        // re-adding a server after signing out never re-runs first-run setup.
        XCTAssertTrue(ProfileStore(defaults: defaults).firstRunProfileSetupComplete())
    }
}

@MainActor
final class FirstRunProfileSeedModelTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "FirstRunProfileSeedModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSeedsDefaultProfileNameAndPhoto() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        XCTAssertEqual(model.profiles.first?.name, "Me")

        model.seedDefaultProfileIdentity(name: "Alice", avatarImageURL: "https://x/a.jpg")

        XCTAssertEqual(model.profiles.first?.name, "Alice")
        XCTAssertEqual(model.profiles.first?.avatarImageURL, "https://x/a.jpg")
    }

    func testSeedIgnoresEmptyValues() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        model.seedDefaultProfileIdentity(name: "Alice", avatarImageURL: "https://x/a.jpg")

        // Blank name / nil photo must not clobber an already-seeded identity.
        model.seedDefaultProfileIdentity(name: "   ", avatarImageURL: nil)

        XCTAssertEqual(model.profiles.first?.name, "Alice")
        XCTAssertEqual(model.profiles.first?.avatarImageURL, "https://x/a.jpg")
    }

    func testMarkCompletePersistsAcrossReload() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertFalse(model.firstRunProfileSetupComplete)

        model.seedDefaultProfileIdentity(name: "Alice", avatarImageURL: nil)
        model.markFirstRunProfileSetupComplete()
        XCTAssertTrue(model.firstRunProfileSetupComplete)

        let reloaded = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertTrue(reloaded.firstRunProfileSetupComplete)
        XCTAssertEqual(reloaded.profiles.first?.name, "Alice")
    }

    func testResetToPristineDefaultCollapsesProfilesAndClearsFlag() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        model.seedDefaultProfileIdentity(name: "Alice", avatarImageURL: "https://x/a.jpg")
        model.markFirstRunProfileSetupComplete()
        _ = model.add(name: "Bob")
        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertTrue(model.firstRunProfileSetupComplete)

        model.resetToPristineDefaultForDebugging()

        // Collapses back to a single pristine "Me" and re-arms first run.
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(model.profiles.first?.name, "Me")
        XCTAssertNil(model.profiles.first?.avatarImageURL)
        XCTAssertFalse(model.firstRunProfileSetupComplete)

        // The wipe must persist so the next launch is a genuine first run.
        let reloaded = ProfilesModel(store: ProfileStore(defaults: defaults))
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.name, "Me")
        XCTAssertFalse(reloaded.firstRunProfileSetupComplete)
    }
}
