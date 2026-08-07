import XCTest
@testable import CoreModels

/// Which profile owns the un-namespaced settings keys must be RECORDED, not
/// derived from list position.
///
/// It used to be "the sentinel default, or else whichever profile sorts first".
/// That made the owner move when the list did, so deleting the first profile
/// would have silently handed its stored settings to whoever became first next —
/// which is why deleting it was refused outright, leaving ordinary profiles
/// permanently undeletable for the accident of being first.
final class ProfileNamespaceOwnershipTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ProfileNamespaceOwnershipTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// The upgrade must not move anybody's settings: whoever owned the bare keys
    /// under the old derived rule still owns them once ownership is recorded.
    @MainActor
    func testExistingInstallKeepsItsLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(AppTheme.pureBlack.rawValue, forKey: "com.plozz.appTheme")

        let model = ProfilesModel(store: ProfileStore(defaults: defaults))

        XCTAssertNil(model.activeNamespace, "the bootstrapped profile still reads the legacy keys")
        XCTAssertEqual(
            ThemeSettingsStore(defaults: defaults, namespace: model.activeNamespace).load(),
            .pureBlack
        )
    }

    /// The heart of it: deleting the owner must not hand its settings to the
    /// profile that takes its place at the head of the list.
    @MainActor
    func testDeletingTheOwnerDoesNotBequeathItsSettings() {
        let defaults = makeDefaults()
        defaults.set(AppTheme.pureBlack.rawValue, forKey: "com.plozz.appTheme")
        let store = ProfileStore(defaults: defaults)
        let model = ProfilesModel(store: store)

        let owner = model.profiles[0]
        let second = model.add(name: "Second")
        // The second profile has its own namespace and its own theme.
        ThemeSettingsStore(
            defaults: defaults,
            namespace: second.settingsNamespace(isDefault: model.isDefault(second))
        ).save(.light)

        model.remove(owner.id)

        XCTAssertFalse(model.profiles.contains { $0.id == owner.id }, "the owner is deletable")
        let survivor = model.profiles[0]
        XCTAssertEqual(survivor.id, second.id)
        XCTAssertFalse(
            model.isDefault(survivor),
            "the survivor must not inherit ownership of the bare keys by moving up the list"
        )
        XCTAssertEqual(
            ThemeSettingsStore(
                defaults: defaults,
                namespace: survivor.settingsNamespace(isDefault: model.isDefault(survivor))
            ).load(),
            .light,
            "the survivor keeps its OWN theme rather than adopting the deleted profile's"
        )
    }

    /// The one invariant that genuinely has to hold.
    @MainActor
    func testTheLastProfileCannotBeDeleted() {
        let model = ProfilesModel(store: ProfileStore(defaults: makeDefaults()))
        XCTAssertEqual(model.profiles.count, 1)

        model.remove(model.profiles[0].id)

        XCTAssertEqual(model.profiles.count, 1, "a household always keeps one profile")
    }

    /// Being first in the list is no longer a reason to be undeletable.
    @MainActor
    func testAnOrdinaryFirstProfileIsDeletable() {
        let defaults = makeDefaults()
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        let first = model.profiles[0]
        _ = model.add(name: "Second")
        _ = model.add(name: "Third")

        model.remove(first.id)

        XCTAssertEqual(model.profiles.count, 2)
        XCTAssertFalse(model.profiles.contains { $0.id == first.id })
    }

    /// Ownership survives a relaunch, so the answer can't drift between runs.
    @MainActor
    func testOwnershipPersistsAcrossReload() {
        let defaults = makeDefaults()
        let first = ProfilesModel(store: ProfileStore(defaults: defaults))
        let ownerID = first.profiles[0].id
        _ = first.add(name: "Second")

        let reloaded = ProfilesModel(store: ProfileStore(defaults: defaults))

        XCTAssertEqual(reloaded.rootNamespaceOwnerID, ownerID)
        XCTAssertTrue(reloaded.isDefault(reloaded.profiles.first { $0.id == ownerID }!))
    }

    /// Once the owner is gone, nobody owns the bare keys — including a profile
    /// added later, which must get its own namespace rather than the leftovers.
    @MainActor
    func testAProfileAddedAfterTheOwnerIsGoneGetsItsOwnNamespace() {
        let defaults = makeDefaults()
        defaults.set(AppTheme.pureBlack.rawValue, forKey: "com.plozz.appTheme")
        let model = ProfilesModel(store: ProfileStore(defaults: defaults))
        let owner = model.profiles[0]
        _ = model.add(name: "Second")
        model.remove(owner.id)

        let newcomer = model.add(name: "Third")

        XCTAssertFalse(model.isDefault(newcomer))
        XCTAssertEqual(
            newcomer.settingsNamespace(isDefault: model.isDefault(newcomer)),
            newcomer.id
        )
        XCTAssertNotEqual(
            ThemeSettingsStore(
                defaults: defaults,
                namespace: newcomer.settingsNamespace(isDefault: model.isDefault(newcomer))
            ).load(),
            .pureBlack,
            "the deleted owner's abandoned keys must not resurface on a new profile"
        )
    }
}
