@testable import AppRuntime
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import FeatureWatchlistCore
import Foundation
@testable import ProviderPlex
import XCTest

/// The read and the write have to agree about which alias a title is watchlisted
/// as, including for a subject that carries no ids of its own.
///
/// A hero fronting an episode promotes the press to the SHOW, and that promoted
/// subject is a bare id + title stub: no provider ids, and no year, so it has no
/// strong evidence and no weak evidence either. On Plex it has no provider
/// binding either, because bindings are minted only for the MediaBrowser
/// providers. Its only durable handle is its ``MediaAliasLocalSourceKey``.
/// Without one, `resolveOrCreate` filed the new record under nothing at all:
/// adding such a title succeeded and then read back as not-added, which is what
/// the viewer saw — "Added to Watchlist", the title really on the list, and a
/// button still offering to add it.
@MainActor
final class UniversalWatchlistMembershipTests: XCTestCase {

    /// The promoted subject exactly as `MediaItem.watchlistSubject` mints it.
    private var promotedSeries: MediaItem {
        MediaItem(
            id: "plex-1234",
            title: "Family Guy",
            kind: .series,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )
    }

    func testPresentationReadinessRejectsPreviousProfileScope() async throws {
        let host = try await UniversalWatchlistHostDouble()
        host.universalWatchlistNativeViewLoaded = true
        host.universalWatchlistProfileID =
            "\(host.profiles.activeProfileID)#0#accounts"

        XCTAssertTrue(host.isUniversalWatchlistPresentationReady)

        host.universalWatchlistProfileID = "another-profile#0#accounts"
        XCTAssertFalse(host.isUniversalWatchlistPresentationReady)
    }

    func testEmptyNativeViewLoadStillNotifiesHomeThatCacheIsReady() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let notification = expectation(
            forNotification: .universalWatchlistCacheDidLoad,
            object: nil
        )

        host.loadUniversalWatchlistNativeView(
            profileID: host.profiles.activeProfileID,
            scope: "empty-cache"
        )

        await fulfillment(of: [notification], timeout: 1)
        XCTAssertTrue(host.universalWatchlistNativeViewLoaded)
        XCTAssertTrue(host.universalWatchlistNativeView.bucketsByDestinationID.isEmpty)
    }

    func testFirstAddOfPromotedSeriesReadsBackAsWatchlisted() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let item = promotedSeries

        XCTAssertFalse(host.universalWatchlistMembership(item))
        // The subject a tvOS/iOS hero promotes an episode to: no catalogue ids,
        // no year, and on Plex no provider binding either.
        let evidence = try XCTUnwrap(host.universalWatchlistEvidence(for: item))
        XCTAssertTrue(evidence.strong.isEmpty)
        XCTAssertNil(evidence.weak)
        XCTAssertTrue(evidence.locallyValidatedBindings.isEmpty)

        let added = await host.performUniversalWatchlist(adding: true, item: item)
        XCTAssertTrue(added)
        // The whole bug: this was false, on a title that had just been added and
        // really was on the list.
        XCTAssertTrue(host.universalWatchlistMembership(item))
    }

    /// And the alias the write addressed is the one the read answers from — the
    /// invariant that keeps a later removal from missing the row the button read.
    func testPromotedSeriesReadAndWriteResolveTheSameAlias() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let item = promotedSeries

        _ = await host.performUniversalWatchlist(adding: true, item: item)

        let read = host.universalWatchlistAliasID(for: item)
        let write = host.universalWatchlistPreferredAliasID(for: item)
        XCTAssertNotNil(read)
        XCTAssertEqual(read, write)
        XCTAssertTrue(
            host.universalWatchlist.activeSnapshot.activeAliasIDs.contains(
                try XCTUnwrap(read)
            )
        )
    }

    /// Removing it again comes off cleanly, so the widened read cannot resurrect a
    /// title by resolving to an alias the removal never touched.
    func testPromotedSeriesRemovesAfterBeingAdded() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let item = promotedSeries

        _ = await host.performUniversalWatchlist(adding: true, item: item)
        XCTAssertTrue(host.universalWatchlistMembership(item))

        let removed = await host.performUniversalWatchlist(adding: false, item: item)

        XCTAssertTrue(removed)
        XCTAssertFalse(host.universalWatchlistMembership(item))
    }

    func testRehydratesEveryPersistedOwnedArtworkField() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let oldClient = PlexClient(
            baseURL: UniversalWatchlistHostDouble.baseURL,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "old"),
            token: "OLD-TOKEN"
        )
        func saved(_ path: String, width: Int?) throws -> URL {
            SyncURLSanitizer.sanitize(
                try XCTUnwrap(
                    oldClient.imageURL(path: path, maxWidth: width)
                )
            )
        }
        let network = try NetworkArtworkReference(
            accountID: "share",
            credentialRevision: CredentialRevision(),
            catalogArtworkID: "network-art",
            representation: RemoteFileRepresentation(
                size: 100,
                identity: RemoteFileIdentity(
                    kind: .modificationTime,
                    modifiedAt: Date(timeIntervalSince1970: 10)
                ),
                consistency: .changeDetecting
            ),
            sourceRevision: "network-revision"
        )
        let remoteSelection = try saved(
            "/library/metadata/4407/art/selection",
            width: 3840
        )
        let item = MediaItem(
            id: "4407",
            title: "Arcane",
            kind: .episode,
            posterURL: try saved(
                "/library/metadata/4407/thumb/poster",
                width: 500
            ),
            seriesPosterURL: try saved(
                "/library/metadata/series/thumb/series",
                width: 500
            ),
            backdropURL: try saved(
                "/library/metadata/4407/art/backdrop",
                width: 1280
            ),
            heroBackdropURL: try saved(
                "/library/metadata/4407/art/hero",
                width: 3840
            ),
            fallbackArtworkURL: try saved(
                "/library/metadata/series/art/fallback",
                width: 1280
            ),
            logoURL: try saved(
                "/library/metadata/series/clearLogo/logo",
                width: nil
            ),
            artworkSelections: [
                ArtworkSelection(
                    placement: .homeHero,
                    references: [
                        .remote(remoteSelection),
                        .networkFile(network)
                    ]
                )
            ],
            locallyValidatedPlayableSource: true,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )

        let provider = try XCTUnwrap(
            host.accountsProviders.provider(
                forAccountID: UniversalWatchlistHostDouble.accountID
            )
        )
        XCTAssertEqual(provider.session.accessToken, "CURRENT-TOKEN")
        XCTAssertNotNil(
            MediaProviderURLIdentity.relativeResourcePath(
                of: try XCTUnwrap(item.posterURL),
                under: UniversalWatchlistHostDouble.baseURL
            )
        )
        XCTAssertNotNil(
            provider.reauthenticatedImageURL(
                try XCTUnwrap(item.posterURL),
                maxWidth: 500
            )
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([item]).first
        )
        let urls = [
            result.posterURL,
            result.seriesPosterURL,
            result.backdropURL,
            result.heroBackdropURL,
            result.fallbackArtworkURL,
            result.logoURL
        ]
        for url in urls {
            let url = try XCTUnwrap(url)
            XCTAssertTrue(url.absoluteString.contains("CURRENT-TOKEN"))
            XCTAssertEqual(
                result.artworkSourceAccountID(for: url),
                UniversalWatchlistHostDouble.accountID
            )
        }
        guard case .remote(let signedSelection) =
                result.artworkSelections[0].references[0] else {
            return XCTFail("Expected remote artwork selection")
        }
        XCTAssertTrue(
            signedSelection.absoluteString.contains("CURRENT-TOKEN")
        )
        XCTAssertEqual(
            result.artworkSourceAccountID(for: signedSelection),
            UniversalWatchlistHostDouble.accountID
        )
        XCTAssertEqual(
            result.artworkSelections[0].references[1],
            .networkFile(network)
        )
    }

    func testOwnedDiscoverArtworkIsSignedWithoutBecomingLocal() async throws {
        let host = try await UniversalWatchlistHostDouble()
        host.plexDiscoverTokens.setToken(
            "DISCOVER-TOKEN",
            for: UniversalWatchlistHostDouble.accountID
        )
        let discover = URL(
            string:
                "https://discover.provider.plex.tv"
                + "/library/metadata/arcane/thumb/1"
        )!
        let item = MediaItem(
            id: "4407",
            title: "Arcane",
            kind: .series,
            posterURL: discover,
            locallyValidatedPlayableSource: true,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([item]).first
        )
        let poster = try XCTUnwrap(result.posterURL)
        XCTAssertEqual(poster.host, discover.host)
        XCTAssertEqual(poster.path, discover.path)
        XCTAssertFalse(poster.path.contains("/photo/:/transcode"))
        XCTAssertTrue(poster.absoluteString.contains("DISCOVER-TOKEN"))
    }

    func testUnownedDiscoverArtworkIsReauthenticated() async throws {
        let host = try await UniversalWatchlistHostDouble()
        host.plexDiscoverTokens.setToken(
            "DISCOVER-TOKEN",
            for: UniversalWatchlistHostDouble.accountID
        )
        let item = MediaItem(
            id: "discover-id",
            title: "Discover title",
            kind: .series,
            posterURL: URL(
                string:
                    "https://discover.provider.plex.tv"
                    + "/library/metadata/discover-id/thumb/1"
            ),
            locallyValidatedPlayableSource: false,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([item]).first
        )
        XCTAssertTrue(
            try XCTUnwrap(result.posterURL)
                .absoluteString.contains("DISCOVER-TOKEN")
        )
    }

    func testDiscoverSignerSurvivesPlaybackRetargetToAnotherProvider() async throws {
        let host = try await UniversalWatchlistHostDouble()
        host.plexDiscoverTokens.setToken(
            "DISCOVER-TOKEN",
            for: UniversalWatchlistHostDouble.accountID
        )
        let discoverItem = MediaItem(
            id: "discover-id",
            title: "Discover title",
            kind: .movie,
            posterURL: URL(
                string:
                    "https://discover.provider.plex.tv"
                    + "/library/metadata/discover-id/thumb/1"
            ),
            locallyValidatedPlayableSource: false
        ).taggingSource(UniversalWatchlistHostDouble.accountID)
        let retargeted = discoverItem.selectingSource(
            MediaSourceRef(
                accountID: "jellyfin-account",
                itemID: "local-id",
                kind: .movie,
                providerKind: .jellyfin
            )
        )

        XCTAssertEqual(retargeted.sourceAccountID, "jellyfin-account")
        XCTAssertEqual(
            retargeted.artworkSourceAccountID,
            UniversalWatchlistHostDouble.accountID
        )
        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([retargeted]).first
        )
        XCTAssertTrue(
            try XCTUnwrap(result.posterURL)
                .absoluteString.contains("DISCOVER-TOKEN")
        )
    }

    func testLocalArtworkSignerSurvivesPlaybackRetarget() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let oldClient = PlexClient(
            baseURL: UniversalWatchlistHostDouble.baseURL,
            deviceProfile: PlexDeviceProfile(clientIdentifier: "old"),
            token: "OLD-TOKEN"
        )
        let persisted = SyncURLSanitizer.sanitize(
            try XCTUnwrap(
                oldClient.imageURL(
                    path: "/library/metadata/4407/thumb/1",
                    maxWidth: 500
                )
            )
        )
        let plexItem = MediaItem(
            id: "4407",
            title: "Arcane",
            kind: .series,
            posterURL: persisted
        ).taggingSource(UniversalWatchlistHostDouble.accountID)
        let retargeted = plexItem.selectingSource(
            MediaSourceRef(
                accountID: "jellyfin-account",
                itemID: "local-id",
                kind: .series,
                providerKind: .jellyfin
            )
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([retargeted]).first
        )
        XCTAssertTrue(
            try XCTUnwrap(result.posterURL)
                .absoluteString.contains("CURRENT-TOKEN")
        )
    }

    func testMissingOwnedArtworkIsRebuiltBeforeFirstPaint() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let item = MediaItem(
            id: "4407",
            title: "Arcane",
            kind: .series,
            locallyValidatedPlayableSource: true,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([item]).first
        )
        let poster = try XCTUnwrap(result.posterURL)
        let backdrop = try XCTUnwrap(result.backdropURL)

        XCTAssertTrue(poster.absoluteString.contains("CURRENT-TOKEN"))
        XCTAssertTrue(backdrop.absoluteString.contains("CURRENT-TOKEN"))
        XCTAssertEqual(
            result.artworkSourceAccountID(for: poster),
            UniversalWatchlistHostDouble.accountID
        )
        XCTAssertEqual(
            result.artworkSourceAccountID(for: backdrop),
            UniversalWatchlistHostDouble.accountID
        )
    }

    func testMissingEpisodeArtworkIsNotInvented() async throws {
        let host = try await UniversalWatchlistHostDouble()
        let item = MediaItem(
            id: "episode-id",
            title: "Episode",
            kind: .episode,
            locallyValidatedPlayableSource: true,
            sourceAccountID: UniversalWatchlistHostDouble.accountID
        )

        let result = try XCTUnwrap(
            host.rehydratedPersistedArtwork([item]).first
        )

        XCTAssertNil(result.posterURL)
        XCTAssertNil(result.seriesPosterURL)
        XCTAssertNil(result.backdropURL)
        XCTAssertNil(result.heroBackdropURL)
    }
}

/// The smallest object that can answer `UniversalWatchlistHost`.
///
/// Only the local halves are real — the watchlist, the alias ledger, the identity
/// index, the accounts and the feature flags. Everything to do with destinations,
/// reconcilers and outboxes is inert: these tests are about how a title resolves
/// to an alias on this device, which is settled before any server is asked.
@MainActor
final class UniversalWatchlistHostDouble: UniversalWatchlistHost {
    let runtimeFeatureFlags = RuntimeFeatureFlags(enabled: [.universalWatchlist])
    let profiles = ProfilesModel()
    let universalWatchlist = WatchlistModel()
    let mediaAliasLedger: MediaAliasLedgerModel
    let identityIndex = IdentityIndexModel(
        activeAccounts: { [] },
        namespace: { nil },
        onPublish: {}
    )
    let accountsProviders: AccountsProvidersModel

    let trackerWatchlistDestinations: [any WatchlistDestination] = []
    let universalWatchlistStorageDirectory: URL? = nil
    var universalWatchlistReconciler: WatchlistReconciler?
    var universalWatchlistMutationStore: DurableWatchlistMutationStore?
    var universalWatchlistNativeView = NativeWatchlistView()
    let universalWatchlistAnimeBridge = AnimeIDBridgeStore(directoryURL: nil)
    var universalWatchlistNativeViewStore: (any NativeWatchlistViewStoring)?
    var universalWatchlistNativeViewLoaded = false
    var universalWatchlistDestinationIDs: Set<WatchlistDestinationID> = []
    var universalWatchlistRefreshGeneration: UInt64 = 0
    var universalWatchlistProfileID: String?
    let plexWatchlistIdentityGeneration = 0
    var universalWatchlistRetryScheduler: WatchlistRetryScheduler?
    var universalWatchlistShouldResumeAuthentication = false
    var universalWatchlistIdentityUpdateTask: Task<Void, Never>?
    let plexDiscoverTokens = PlexDiscoverTokenBox()
    let activeProfileAwaitsUnlock = false

    private(set) var cloudPublishCount = 0

    static let accountID = "acct"
    static let baseURL = URL(string: "http://plex.local:32400")!

    init() async throws {
        mediaAliasLedger = await MediaAliasLedgerModel()
        // A real signed-in Plex account, because the write derives its provider
        // binding from one: `universalWatchlistEvidence` looks the account's
        // provider kind up to decide whether the `(account, id)` pair is a
        // media-browser binding at all.
        let store = AccountStore(secureStore: InMemorySecureStore())
        try store.add(
            Account(
                id: Self.accountID,
                server: MediaServer(
                    id: "universal-watchlist-\(UUID().uuidString)",
                    name: "Plex",
                    baseURL: Self.baseURL,
                    provider: .plex
                ),
                userID: "u",
                userName: "Viewer",
                deviceID: store.deviceID()
            ),
            token: "CURRENT-TOKEN"
        )
        store.setActiveAccountIDs([Self.accountID])
        let registry = ProviderRegistry()
        registry.register(.plex) { context in
            PlexProvider(
                session: context.session,
                accountID: context.accountID,
                credentialRevision: context.credentialRevision
            )
        }
        accountsProviders = AccountsProvidersModel(
            accountStore: store,
            registry: registry,
            profilesModel: profiles
        )
        accountsProviders.tokenResolver = { store.token(for: $0) }
        accountsProviders.reloadAccounts()
        try universalWatchlist.activate(profileID: profiles.activeProfileID)
        try await mediaAliasLedger.activate(profileID: profiles.activeProfileID)
    }

    func scheduleCloudPublish() { cloudPublishCount += 1 }
    func ensureTrackersScopedToActiveProfile() async {}
}
