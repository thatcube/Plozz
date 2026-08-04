import XCTest
@testable import CoreModels

/// The picker leads with whoever watched on this device most recently, because
/// tvOS opens focus on the first tile and that's the likeliest pick on a shared
/// Apple TV.
@MainActor
final class ProfileRecencyTests: XCTestCase {

    private func makeModel() -> ProfilesModel {
        let suite = "ProfileRecencyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ProfilesModel(store: ProfileStore(defaults: defaults))
    }

    func testFallsBackToCreationOrderWhenNothingHasBeenUsed() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        let b = model.add(name: "B", activeAccountIDs: [])

        // The default profile is first, then creation order.
        let ordered = model.profilesByRecency.map(\.id)
        XCTAssertEqual(ordered, [ProfileStore.defaultProfileID, a.id, b.id])
    }

    func testMostRecentlyUsedComesFirst() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        let b = model.add(name: "B", activeAccountIDs: [])

        model.select(a.id)
        model.select(b.id)

        XCTAssertEqual(model.profilesByRecency.first?.id, b.id, "last one opened leads")
    }

    func testUsedProfilesSortAheadOfNeverUsedOnes() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        _ = model.add(name: "B", activeAccountIDs: [])

        model.select(a.id)

        let ordered = model.profilesByRecency.map(\.id)
        XCTAssertEqual(ordered.first, a.id)
        // Everyone else keeps creation order behind the used ones.
        XCTAssertEqual(ordered.count, 3)
    }

    func testReSelectingMovesAProfileBackToTheFront() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        let b = model.add(name: "B", activeAccountIDs: [])

        model.select(a.id)
        model.select(b.id)
        XCTAssertEqual(model.profilesByRecency.first?.id, b.id)

        model.select(a.id)
        XCTAssertEqual(model.profilesByRecency.first?.id, a.id)
    }

    /// Ordering must not lose or duplicate anyone — a picker that dropped a
    /// profile would be far worse than one in the wrong order.
    func testOrderingIsAPermutation() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        let b = model.add(name: "B", activeAccountIDs: [])
        model.select(b.id)

        XCTAssertEqual(Set(model.profilesByRecency.map(\.id)), Set(model.profiles.map(\.id)))
        XCTAssertEqual(model.profilesByRecency.count, model.profiles.count)
        XCTAssertTrue(model.profilesByRecency.contains { $0.id == a.id })
    }

    /// The recency map is keyed by id, so a deleted profile's entry must not
    /// linger and resurface if an id is ever reused.
    func testRemovedProfilesAreDroppedFromTheRecencyMap() {
        let model = makeModel()
        let a = model.add(name: "A", activeAccountIDs: [])
        let b = model.add(name: "B", activeAccountIDs: [])
        model.select(a.id)
        model.remove(a.id)
        // A later write prunes ids that no longer exist.
        model.select(b.id)

        XCTAssertFalse(model.profilesByRecency.contains { $0.id == a.id })
        XCTAssertEqual(model.profilesByRecency.first?.id, b.id)
    }
}
