import XCTest
@testable import CoreModels

@MainActor
final class ReleaseNotesTests: XCTestCase {
    func testCatalogDecodesAndGroupsSameVersionBuilds() throws {
        let catalog = try makeCatalog()

        XCTAssertEqual(catalog.releases.map(\.id), ["release/003", "release/002", "release/001"])
        XCTAssertEqual(catalog.allGroups.map(\.version), ["2026.8.2", "2026.8.1"])
        XCTAssertEqual(
            catalog.allGroups[0].sections,
            [
                ReleaseNotesSection(category: .new, items: ["New three"]),
                ReleaseNotesSection(category: .updated, items: ["Updated three", "Updated two"]),
                ReleaseNotesSection(category: .fixed, items: ["Fixed two"])
            ]
        )
    }

    func testLegacyStringItemsAreSharedAcrossPlatforms() throws {
        let catalog = try ReleaseNotesCatalog(data: Data("""
        {
          "schemaVersion": 1,
          "releases": [{
            "id": "release/001",
            "version": "2026.8.1",
            "build": 1,
            "releasedAt": "2026-08-01",
            "sections": [{ "category": "New", "items": ["Shared"] }]
          }]
        }
        """.utf8))

        XCTAssertEqual(
            catalog.versionGroups(platform: .tvOS)[0].sections[0].items,
            [ReleaseNotesItem(text: "Shared")]
        )
        XCTAssertEqual(
            catalog.versionGroups(platform: .iOS)[0].sections[0].items,
            [ReleaseNotesItem(text: "Shared")]
        )
    }

    func testLegacySharedItemEncodesBackToAString() throws {
        let item = ReleaseNotesItem(text: "Shared")

        let encoded = try JSONEncoder().encode(item)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"Shared\"")
    }

    func testPlatformItemsFilterAndKeepCategoryOrder() throws {
        let catalog = try platformCatalog()
        let tvGroup = try XCTUnwrap(
            catalog.versionGroups(platform: .tvOS).first {
                $0.version == "2026.8.1"
            }
        )
        let phoneGroup = try XCTUnwrap(
            catalog.versionGroups(platform: .iOS).first {
                $0.version == "2026.8.1"
            }
        )

        XCTAssertEqual(
            tvGroup.sections,
            [
                ReleaseNotesSection(
                    category: .new,
                    items: [
                        ReleaseNotesItem(text: "Shared"),
                        ReleaseNotesItem(text: "TV only", platforms: [.tvOS])
                    ]
                )
            ]
        )
        XCTAssertEqual(
            phoneGroup.sections,
            [
                ReleaseNotesSection(
                    category: .new,
                    items: [
                        ReleaseNotesItem(text: "Shared"),
                        ReleaseNotesItem(text: "Phone only", platforms: [.iOS])
                    ]
                ),
                ReleaseNotesSection(
                    category: .fixed,
                    items: [
                        ReleaseNotesItem(text: "Phone fix", platforms: [.iOS])
                    ]
                )
            ]
        )
    }

    func testFirstReleasedBuildEstablishesBaselineWithoutPresenting() throws {
        let store = TestReleaseNotesStore()
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testUpdatePresentsEveryUnseenReleaseNewestFirst() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/003",
            store: store
        )

        model.prepareForStartup()

        XCTAssertEqual(model.pendingReleases.map(\.id), ["release/003", "release/002"])
        XCTAssertEqual(model.pendingVersionGroups.map(\.version), ["2026.8.2"])
        XCTAssertEqual(store.lastSeenReleaseID, "release/001")

        model.dismissStartupNotes()
        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testDisabledAnnouncementsAdvanceSeenReleaseWithoutPresenting() throws {
        let store = TestReleaseNotesStore(
            showsOnStartup: false,
            lastSeenReleaseID: "release/001"
        )
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testReenablingDoesNotPresentBacklog() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.setShowsOnStartup(false)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")

        model.setShowsOnStartup(true)
        model.prepareForStartup()

        XCTAssertTrue(model.showsOnStartup)
        XCTAssertFalse(model.hasPendingStartupNotes)
    }

    func testDowngradeDoesNotMoveSeenReleaseBackward() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/003")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/002",
            store: store
        )

        model.prepareForStartup()
        model.dismissStartupNotes()

        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testMissingLastSeenReleaseReestablishesBaseline() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/999")
        let model = ReleaseNotesModel(
            catalog: try makeCatalog(),
            currentReleaseID: "release/003",
            store: store
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/003")
    }

    func testPlatformWithNoRelevantNotesAdvancesWithoutPresenting() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try platformCatalog(),
            currentReleaseID: "release/002",
            store: store,
            platform: .iOS
        )

        model.prepareForStartup()

        XCTAssertFalse(model.hasPendingStartupNotes)
        XCTAssertEqual(store.lastSeenReleaseID, "release/002")
    }

    func testSkippedUpdatePresentsOnlyRelevantPlatformReleases() throws {
        let store = TestReleaseNotesStore(lastSeenReleaseID: "release/001")
        let model = ReleaseNotesModel(
            catalog: try platformCatalog(),
            currentReleaseID: "release/003",
            store: store,
            platform: .tvOS
        )

        model.prepareForStartup()

        XCTAssertEqual(model.pendingReleases.map(\.id), ["release/002"])
        XCTAssertEqual(
            model.pendingVersionGroups[0].sections[0].items.map(\.text),
            ["TV update"]
        )
    }

    func testBundledCatalogPassesRuntimeValidation() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let catalogURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Resources/ReleaseNotes.json")

        XCTAssertNoThrow(
            try ReleaseNotesCatalog(data: Data(contentsOf: catalogURL))
        )
    }

    func testCatalogRejectsDuplicateBuild() {
        let duplicateBuild = """
        {
          "schemaVersion": 1,
          "releases": [
            {
              "id": "release/002",
              "version": "2026.8.2",
              "build": 2,
              "releasedAt": "2026-08-02",
              "sections": [{ "category": "New", "items": ["One"] }]
            },
            {
              "id": "release/003",
              "version": "2026.8.1",
              "build": 2,
              "releasedAt": "2026-08-01",
              "sections": [{ "category": "Fixed", "items": ["Two"] }]
            }
          ]
        }
        """

        XCTAssertThrowsError(try ReleaseNotesCatalog(data: Data(duplicateBuild.utf8))) { error in
            XCTAssertEqual(error as? ReleaseNotesCatalogError, .duplicateBuild(2))
        }
    }

    func testCatalogRejectsEmptyPlatformTarget() {
        let emptyPlatforms = """
        {
          "schemaVersion": 1,
          "releases": [{
            "id": "release/001",
            "version": "2026.8.1",
            "build": 1,
            "releasedAt": "2026-08-01",
            "sections": [{
              "category": "New",
              "items": [{ "text": "Nothing", "platforms": [] }]
            }]
          }]
        }
        """

        XCTAssertThrowsError(
            try ReleaseNotesCatalog(data: Data(emptyPlatforms.utf8))
        ) { error in
            XCTAssertEqual(
                error as? ReleaseNotesCatalogError,
                .emptyPlatforms("release/001", .new)
            )
        }
    }

    private func makeCatalog() throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog(
            releases: [
                ReleaseNotesRelease(
                    id: "release/003",
                    version: "2026.8.2",
                    build: 3,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(category: .new, items: ["New three"]),
                        ReleaseNotesSection(category: .updated, items: ["Updated three"])
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/002",
                    version: "2026.8.2",
                    build: 2,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(category: .updated, items: ["Updated two"]),
                        ReleaseNotesSection(category: .fixed, items: ["Fixed two"])
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/001",
                    version: "2026.8.1",
                    build: 1,
                    releasedAt: "2026-08-01",
                    sections: [
                        ReleaseNotesSection(category: .new, items: ["New one"])
                    ]
                )
            ]
        )
    }

    private func platformCatalog() throws -> ReleaseNotesCatalog {
        try ReleaseNotesCatalog(
            releases: [
                ReleaseNotesRelease(
                    id: "release/003",
                    version: "2026.8.3",
                    build: 3,
                    releasedAt: "2026-08-03",
                    sections: [
                        ReleaseNotesSection(
                            category: .updated,
                            items: [
                                ReleaseNotesItem(
                                    text: "Phone update",
                                    platforms: [.iOS]
                                )
                            ]
                        )
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/002",
                    version: "2026.8.2",
                    build: 2,
                    releasedAt: "2026-08-02",
                    sections: [
                        ReleaseNotesSection(
                            category: .updated,
                            items: [
                                ReleaseNotesItem(
                                    text: "TV update",
                                    platforms: [.tvOS]
                                )
                            ]
                        )
                    ]
                ),
                ReleaseNotesRelease(
                    id: "release/001",
                    version: "2026.8.1",
                    build: 1,
                    releasedAt: "2026-08-01",
                    sections: [
                        ReleaseNotesSection(
                            category: .new,
                            items: [
                                ReleaseNotesItem(text: "Shared"),
                                ReleaseNotesItem(
                                    text: "TV only",
                                    platforms: [.tvOS]
                                ),
                                ReleaseNotesItem(
                                    text: "Phone only",
                                    platforms: [.iOS]
                                )
                            ]
                        ),
                        ReleaseNotesSection(
                            category: .fixed,
                            items: [
                                ReleaseNotesItem(
                                    text: "Phone fix",
                                    platforms: [.iOS]
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    }
}

private extension ReleaseNotesCatalog {
    var allGroups: [ReleaseNotesVersionGroup] {
        versionGroups()
    }
}

private final class TestReleaseNotesStore: ReleaseNotesStoring, @unchecked Sendable {
    var showsOnStartup: Bool
    var lastSeenReleaseID: String?

    init(showsOnStartup: Bool = true, lastSeenReleaseID: String? = nil) {
        self.showsOnStartup = showsOnStartup
        self.lastSeenReleaseID = lastSeenReleaseID
    }

    func loadShowsOnStartup() -> Bool {
        showsOnStartup
    }

    func saveShowsOnStartup(_ showsOnStartup: Bool) {
        self.showsOnStartup = showsOnStartup
    }

    func loadLastSeenReleaseID() -> String? {
        lastSeenReleaseID
    }

    func saveLastSeenReleaseID(_ releaseID: String) {
        lastSeenReleaseID = releaseID
    }
}
