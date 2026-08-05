import CoreModels
import XCTest
@testable import FeatureWatchlistCore

/// The watchlist a viewer sees is durable intent PLUS what the servers they have
/// switched on currently hold, minus what they explicitly removed.
///
/// These cover the failure that motivated the read-time view: the old import
/// promoted "server X's list holds this" into "the viewer wants this", which made
/// it unretractable — switching the server off left everything it had contributed
/// behind, and the only way out was deleting each title by hand.
@MainActor
final class WatchlistUnionTests: XCTestCase {
    private let plex = WatchlistDestinationID(rawValue: "plex")!
    private let jellyfin = WatchlistDestinationID(rawValue: "jellyfin")!

    private func view(
        _ buckets: [(WatchlistDestinationID, [MediaAliasID])]
    ) -> NativeWatchlistView {
        var value = NativeWatchlistView()
        for (destinationID, aliases) in buckets {
            value.applySuccess(
                destinationID: destinationID,
                entries: aliases.enumerated().compactMap { offset, aliasID in
                    NativeWatchlistEntry(
                        aliasID: aliasID,
                        kind: .movie,
                        index: offset
                    )
                }
            )
        }
        return value
    }

    /// The whole point: a server's titles show up without becoming intent, so
    /// there is nothing durable to retract later.
    func testNativeEntryAppearsWithoutWritingAnIntent() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        try model.activate(profileID: "p")

        let union = model.union(
            profileID: "p",
            nativeView: view([(plex, [alias])]),
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex]
        )

        XCTAssertTrue(union.contains(aliasID: alias))
        XCTAssertTrue(model.activeSnapshot.orderedEntries.isEmpty)
        XCTAssertNil(model.activeSnapshot.intent(for: alias))
    }

    /// Switching a server off retracts its contribution for free. This is the
    /// bug report: "I turned the server off and the titles are still there."
    func testDisablingADestinationRemovesItsTitlesAndLeavesTheLedgerAlone() throws {
        let model = WatchlistModel()
        let owned = MediaAliasID()
        let fromServer = MediaAliasID()
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: owned, kind: .movie)
        let nativeView = view([(plex, [fromServer])])

        let enabled = model.union(
            profileID: "p",
            nativeView: nativeView,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex]
        )
        let disabled = model.union(
            profileID: "p",
            nativeView: nativeView,
            aliasSnapshot: .empty,
            enabledDestinationIDs: []
        )

        XCTAssertEqual(enabled.orderedEntries.count, 2)
        XCTAssertEqual(disabled.orderedEntries.map(\.aliasID), [owned])
        // Nothing was undone, because nothing was ever written.
        XCTAssertEqual(model.activeSnapshot.orderedEntries.count, 1)
    }

    /// One server going quiet must not empty the watchlist, and one that answers
    /// with nothing must not be papered over. Home learned this the hard way.
    func testFailedReadKeepsTitlesWhileSuccessfulEmptyReadClearsThem() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        try model.activate(profileID: "p")
        var nativeView = view([(plex, [alias])])

        nativeView.applyFailure(destinationID: plex)
        let offline = model.union(
            profileID: "p",
            nativeView: nativeView,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex]
        )
        XCTAssertTrue(offline.contains(aliasID: alias))
        // Callers can say the list may be incomplete rather than present it as
        // the whole truth.
        XCTAssertTrue(offline.hasStaleDestinations)

        nativeView.applySuccess(destinationID: plex, entries: [])
        let cleared = model.union(
            profileID: "p",
            nativeView: nativeView,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex]
        )
        XCTAssertFalse(cleared.contains(aliasID: alias))
        XCTAssertFalse(cleared.hasStaleDestinations)
    }

    /// Switching "watching as" must not show one person the other's watchlist.
    ///
    /// A Plex destination is `plex.<accountID>` whatever Home user the profile
    /// plays as, so the previous person's entries sit under the same key — and a
    /// failed read deliberately KEEPS what it has, which would have made that
    /// stick indefinitely rather than for a moment.
    func testEntriesReadAsAnotherIdentityAreDropped() {
        var stored = NativeWatchlistView(identityScope: "p#1")
        stored.applySuccess(
            destinationID: plex,
            entries: [
                NativeWatchlistEntry(
                    aliasID: MediaAliasID(),
                    kind: .movie,
                    index: 0
                )!
            ]
        )

        let sameIdentity = stored.scoped(to: "p#1")
        let switchedIdentity = stored.scoped(to: "p#2")

        XCTAssertEqual(sameIdentity.bucket(for: plex)?.entries.count, 1)
        XCTAssertNil(switchedIdentity.bucket(for: plex))
        XCTAssertEqual(switchedIdentity.identityScope, "p#2")
    }

    /// A destination that has never been read successfully gets no bucket at
    /// all. Inventing an empty one would claim knowledge we don't have.
    func testFailureBeforeAnySuccessfulReadRecordsNothing() {
        var nativeView = NativeWatchlistView()
        nativeView.applyFailure(destinationID: plex)
        XCTAssertNil(nativeView.bucket(for: plex))
    }

    /// Two servers listing the same film is one row, not two.
    func testSameTitleOnTwoServersAppearsOnce() throws {
        let model = WatchlistModel()
        let alias = MediaAliasID()
        try model.activate(profileID: "p")

        let union = model.union(
            profileID: "p",
            nativeView: view([(plex, [alias]), (jellyfin, [alias])]),
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex, jellyfin]
        )

        XCTAssertEqual(union.orderedEntries.map(\.aliasID), [alias])
    }

    /// An explicit add that a server also lists stays the viewer's own, and
    /// keeps its place at the front rather than being re-sorted into the
    /// server's order.
    func testExplicitAddAlsoHeldByAServerStaysExplicitAndKeepsItsPlace() throws {
        let model = WatchlistModel()
        let owned = MediaAliasID()
        let other = MediaAliasID()
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: owned, kind: .movie)

        let union = model.union(
            profileID: "p",
            nativeView: view([(plex, [other, owned])]),
            aliasSnapshot: .empty,
            enabledDestinationIDs: [plex]
        )

        XCTAssertEqual(union.orderedEntries.map(\.aliasID), [owned, other])
        XCTAssertEqual(union.orderedEntries.map(\.isExplicit), [true, false])
    }
}

/// Picking the right COPY of a correctly identified title.
///
/// The alias ledger answers "what title is this?"; it does not answer "and which
/// item on your servers is it?". The watchlist row's own items come from Plex
/// Discover and carry "not in your library" by construction, so matching one by
/// alias and handing it straight back shows a film you own as something to
/// request. Right title, wrong copy.
@MainActor
final class WatchlistPresentationRetargetTests: XCTestCase {
    func testDiscoveryCandidateIsUpgradedToTheOwnedLibraryCopy() throws {
        let aliasID = MediaAliasID()
        let union = WatchlistUnion(
            snapshot: WatchlistSnapshot(intents: [
                WatchlistIntent(
                    aliasID: aliasID,
                    kind: .movie,
                    desiredState: .present,
                    rank: 0,
                    origin: .local,
                    presentation: MediaAliasPresentation(
                        title: "The Unhealer",
                        year: 2020
                    )
                )!
            ]),
            nativeView: .empty,
            aliasSnapshot: .empty,
            enabledDestinationIDs: []
        )
        // What a Plex watchlist row actually offers: the Discover copy.
        var discovery = MediaItem(
            id: "discover-1",
            title: "The Unhealer",
            kind: .movie,
            providerIDs: ["Imdb": "tt9204204"],
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )
        discovery.sourceAccountID = "plex-account"
        let owned = MediaSourceRef(
            accountID: "plex-account",
            itemID: "library-rating-key",
            kind: .movie,
            providerKind: .plex
        )

        let resolved = WatchlistPresentationResolver.resolve(
            union: union,
            aliasSnapshot: .empty,
            currentItemsByAliasID: [aliasID: discovery],
            indexedSources: { _ in [owned] }
        )

        let item = try XCTUnwrap(resolved.first?.item)
        XCTAssertTrue(
            item.locallyValidatedPlayableSource,
            "A watchlisted film sitting in the library must not render as one to request"
        )
        XCTAssertNil(item.availability)
    }

    /// The upgrade must never invent a match. Retargeting on title+year alone
    /// wouldn't just mislabel a card, it would route playback to another work.
    func testCandidateWithoutAStrongIDIsLeftAlone() throws {
        let aliasID = MediaAliasID()
        let union = WatchlistUnion(
            snapshot: WatchlistSnapshot(intents: [
                WatchlistIntent(
                    aliasID: aliasID,
                    kind: .movie,
                    desiredState: .present,
                    rank: 0,
                    origin: .local,
                    presentation: MediaAliasPresentation(title: "Ambiguous", year: 2020)
                )!
            ]),
            nativeView: .empty,
            aliasSnapshot: .empty,
            enabledDestinationIDs: []
        )
        let discovery = MediaItem(
            id: "discover-2",
            title: "Ambiguous",
            kind: .movie,
            availability: .unknown,
            locallyValidatedPlayableSource: false
        )

        let resolved = WatchlistPresentationResolver.resolve(
            union: union,
            aliasSnapshot: .empty,
            currentItemsByAliasID: [aliasID: discovery],
            indexedSources: { _ in
                [
                    MediaSourceRef(
                        accountID: "a",
                        itemID: "wrong-film",
                        kind: .movie,
                        providerKind: .plex
                    )
                ]
            }
        )

        let item = try XCTUnwrap(resolved.first?.item)
        XCTAssertFalse(item.locallyValidatedPlayableSource)
        XCTAssertEqual(item.availability, .unknown)
    }
}

/// What reaches CloudKit, and what the one-shot migration keeps.
@MainActor
final class WatchlistNativeRetirementTests: XCTestCase {
    /// Only what the viewer asked for syncs. A title that is here purely because
    /// a server lists it must never become a record on another device, where
    /// that server may not even be signed in.
    func testSyncCapturesExplicitIntentOnly() throws {
        let model = WatchlistModel()
        let owned = MediaAliasID()
        let fromServer = MediaAliasID()
        let destination = WatchlistDestinationID(rawValue: "plex")!
        try model.activate(profileID: "p")
        try model.add(profileID: "p", aliasID: owned, kind: .movie)

        var nativeView = NativeWatchlistView()
        nativeView.applySuccess(
            destinationID: destination,
            entries: [
                NativeWatchlistEntry(aliasID: fromServer, kind: .movie, index: 0)!
            ]
        )
        XCTAssertTrue(model.union(
            profileID: "p",
            nativeView: nativeView,
            aliasSnapshot: .empty,
            enabledDestinationIDs: [destination]
        ).contains(aliasID: fromServer))

        let records = try model.captureSyncRecords(profileID: "p")

        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[WatchlistMediaStateRecordKey(
            profileID: "p",
            aliasID: owned
        ).recordName])
        XCTAssertNil(records[WatchlistMediaStateRecordKey(
            profileID: "p",
            aliasID: fromServer
        ).recordName])
    }

    /// The migration drops what the import wrote and nothing else.
    ///
    /// `.legacyHomeSeed` stays because it came from the old cached Home row, not
    /// from a live server — there may be no native source left to restore it, so
    /// dropping it would silently lose titles.
    func testRetirementDropsImportedIntentsAndKeepsTheRest() throws {
        let store = InMemoryWatchlistIntentStore(
            WatchlistIntentStoreState(intents: [
                intent(origin: .local, rank: 0),
                intent(origin: .legacyHomeSeed, rank: 1),
                intent(origin: .cloud, rank: 2),
                intent(origin: .nativeImport, rank: 3),
                intent(origin: .nativeImport, rank: 4)
            ])
        )
        let model = WatchlistModel(storeFactory: { _ in store })
        try model.activate(profileID: "p")

        let retired = try model.retireNativeImports(profileID: "p")

        XCTAssertEqual(retired, 2)
        XCTAssertEqual(
            Set(model.activeSnapshot.intentsByAliasID.values.map(\.origin)),
            [.local, .legacyHomeSeed, .cloud]
        )
        // Once only: a second pass must not re-run on every launch.
        XCTAssertEqual(try model.retireNativeImports(profileID: "p"), 0)
    }

    /// A removal with no recorded supersession keeps hiding the title. Treating
    /// an unknown removal as already answered would un-hide things people
    /// deleted, including ones that arrived as tombstones over sync.
    func testUnknownRemovalStillSuppresses() {
        XCTAssertTrue(
            WatchlistIntentMetadata().suppressesNativePresence
        )
        XCTAssertTrue(
            WatchlistIntentMetadata(
                lastExplicitRemovalAt: Date(timeIntervalSince1970: 100),
                removalSupersededAt: Date(timeIntervalSince1970: 50)
            ).suppressesNativePresence
        )
        XCTAssertFalse(
            WatchlistIntentMetadata(
                lastExplicitRemovalAt: Date(timeIntervalSince1970: 100),
                removalSupersededAt: Date(timeIntervalSince1970: 150)
            ).suppressesNativePresence
        )
    }

    /// The supersession timestamp has to survive the round trip, or a device
    /// that syncs a superseded removal would start hiding the title again.
    func testSupersessionSurvivesSyncRoundTrip() throws {
        let value = WatchlistIntent(
            aliasID: MediaAliasID(),
            kind: .movie,
            desiredState: .absent,
            rank: 0,
            origin: .local,
            metadata: WatchlistIntentMetadata(
                lastExplicitRemovalAt: Date(timeIntervalSince1970: 100),
                removalSupersededAt: Date(timeIntervalSince1970: 150)
            )
        )!
        let encoded = try XCTUnwrap(
            CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: value))
        )
        let decoded = try XCTUnwrap(
            CanonicalJSON.decode(WatchlistIntentSyncDTO.self, from: encoded)
        ).makeIntent()

        XCTAssertEqual(
            decoded?.metadata.removalSupersededAt,
            Date(timeIntervalSince1970: 150)
        )
        XCTAssertFalse(decoded?.metadata.suppressesNativePresence ?? true)
    }

    private func intent(
        origin: WatchlistIntentOrigin,
        rank: UInt64
    ) -> WatchlistIntent {
        WatchlistIntent(
            aliasID: MediaAliasID(),
            kind: .movie,
            desiredState: .present,
            rank: rank,
            origin: origin
        )!
    }
}
