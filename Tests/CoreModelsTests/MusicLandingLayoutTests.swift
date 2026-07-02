import XCTest
@testable import CoreModels

/// Tests for the data-driven Music landing layout — the ordered, toggleable list
/// of sections the landing view iterates instead of a hardcoded body.
final class MusicLandingLayoutTests: XCTestCase {

    func testDefaultOrder() {
        XCTAssertEqual(
            MusicLandingLayout.default.visibleSections,
            [.browse, .recentlyPlayed, .playlists, .albums, .artists]
        )
    }

    func testReorderAndHideAreHonored() {
        let layout = MusicLandingLayout(items: [
            .init(section: .albums),
            .init(section: .recentlyPlayed, isVisible: false),
            .init(section: .artists),
            .init(section: .browse, isVisible: false),
            .init(section: .playlists)
        ])
        XCTAssertEqual(layout.visibleSections, [.albums, .artists, .playlists])
    }

    func testMissingSectionsAppendInDefaultPositionForwardCompatibility() {
        // A persisted (older) layout that only knew about two sections still
        // surfaces the newer ones, appended in their default position.
        let layout = MusicLandingLayout(items: [
            .init(section: .albums),
            .init(section: .artists)
        ])
        XCTAssertEqual(
            layout.visibleSections,
            [.albums, .artists, .browse, .recentlyPlayed, .playlists]
        )
    }

    func testRoundTripsThroughStore() {
        let suite = "MusicLandingLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = MusicLandingLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load(), .default, "an empty store yields the shipped default")

        let custom = MusicLandingLayout(items: [
            .init(section: .recentlyPlayed),
            .init(section: .albums)
        ])
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }

    func testEphemeralStoreRoundTrips() {
        let store = EphemeralMusicLandingLayoutStore()
        XCTAssertEqual(store.load(), .default)
        let custom = MusicLandingLayout(items: [.init(section: .playlists)])
        store.save(custom)
        XCTAssertEqual(store.load(), custom)
    }
}
