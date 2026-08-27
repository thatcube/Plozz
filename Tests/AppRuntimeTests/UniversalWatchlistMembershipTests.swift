@testable import AppRuntime
import CoreModels
import CoreSecureStore
import FeatureAuthCore
import FeatureWatchlistCore
import Foundation
import ProviderPlex
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
    var universalWatchlistProfileID: String?
    let plexWatchlistIdentityGeneration = 0
    var universalWatchlistRetryScheduler: WatchlistRetryScheduler?
    var universalWatchlistShouldResumeAuthentication = false
    var universalWatchlistIdentityUpdateTask: Task<Void, Never>?
    let plexDiscoverTokens = PlexDiscoverTokenBox()
    let activeProfileAwaitsUnlock = false

    private(set) var cloudPublishCount = 0

    static let accountID = "acct"

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
                    id: "server",
                    name: "Plex",
                    baseURL: URL(string: "http://plex.local:32400")!,
                    provider: .plex
                ),
                userID: "u",
                userName: "Viewer",
                deviceID: store.deviceID()
            ),
            token: "t"
        )
        store.setActiveAccountIDs([Self.accountID])
        accountsProviders = AccountsProvidersModel(
            accountStore: store,
            registry: ProviderRegistry(),
            profilesModel: profiles
        )
        accountsProviders.reloadAccounts()
        try universalWatchlist.activate(profileID: profiles.activeProfileID)
        try await mediaAliasLedger.activate(profileID: profiles.activeProfileID)
    }

    func scheduleCloudPublish() { cloudPublishCount += 1 }
    func ensureTrackersScopedToActiveProfile() async {}
}
