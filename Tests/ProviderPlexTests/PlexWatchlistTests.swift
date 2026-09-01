import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderPlex

/// Feature B (unified Watchlist) on the Plex provider: the account-level
/// plex.tv Discover writes keyed by the global `plex://` guid, plus the guid
/// stashing that makes them addressable.
final class PlexWatchlistTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    // MARK: - guid keying

    func testWatchlistMetadataIDExtractsGuidTail() {
        XCTAssertEqual(PlexClient.watchlistMetadataID(fromGuid: "plex://movie/5d776b9a"), "5d776b9a")
        XCTAssertEqual(PlexClient.watchlistMetadataID(fromGuid: "plex://show/abc123"), "abc123")
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: "imdb://tt0083658"))
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: nil))
        XCTAssertNil(PlexClient.watchlistMetadataID(fromGuid: "plex://movie/"))
    }

    func testProviderIDsStashesPlexGuid() {
        let json = """
        {"ratingKey":"101","type":"movie","title":"Dune","guid":"plex://movie/xyz",
         "Guid":[{"id":"imdb://tt1160419"}]}
        """
        let dto = try! JSONDecoder.plozz.decode(PlexMetadata.self, from: Data(json.utf8))
        let ids = PlexProvider.providerIDs(from: dto)
        XCTAssertEqual(ids["PlexGuid"], "plex://movie/xyz")
        XCTAssertEqual(ids["Imdb"], "tt1160419")
    }

    // MARK: - setWatchlisted via Discover

    func testSetWatchlistedThrowsWithoutGuid() async {
        let stub = StubHTTPClient()
        let provider = PlexProvider(session: makeSession(), http: stub)
        let item = MediaItem(id: "101", title: "m", kind: .movie)
        do {
            try await provider.setWatchlisted(true, item: item)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testSetWatchlistedAddsViaDiscover() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(true, item: item)

        XCTAssertEqual(stub.method(forPathSuffix: "/actions/addToWatchlist"), .put)
        let query = stub.queryItems(forPathSuffix: "/actions/addToWatchlist") ?? []
        XCTAssertTrue(query.contains { $0.name == "ratingKey" && $0.value == "abc123" })
    }

    func testSetWatchlistedRemoveUsesRemoveAction() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/removeFromWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(false, item: item)

        XCTAssertEqual(stub.method(forPathSuffix: "/actions/removeFromWatchlist"), .put)
    }

    // MARK: - watchlist() read

    func testWatchlistMapsItemsAsFavorited() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"g1","type":"movie","title":"Dune","year":2021}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()
        XCTAssertEqual(items.map(\.title), ["Dune"])
        XCTAssertTrue(items.first?.isFavorite ?? false)
        XCTAssertFalse(
            items.first?.locallyValidatedPlayableSource ?? true
        )
    }

    /// Regression: the watchlist READ must hit `discover.provider.plex.tv`, not
    /// the legacy `metadata.provider.plex.tv` host (which now 404s — reads were
    /// migrated to the Discover host, matching the write action's host).
    func testWatchlistReadUsesDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":0,"Metadata":[]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try await provider.watchlist()

        let host = stub.baseURL(forPathSuffix: "/library/sections/watchlist/all")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    /// Regression: the watchlist read must ASK for external ids.
    ///
    /// Without `includeGuids=1` Plex returns only its own `plex://` guid, which
    /// identifies a title inside Plex and nowhere else. Every watchlisted title
    /// then arrived with no evidence of what it IS and could only be matched on
    /// title+year — so a watchlisted film couldn't be recognised as the copy
    /// already in the library ("not in your library — request it"), and its
    /// detail page couldn't tell it was on the watchlist at all.
    func testWatchlistReadAsksForExternalIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":0,"Metadata":[]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try await provider.watchlist()

        let query = stub.queryItems(forPathSuffix: "/library/sections/watchlist/all")
        XCTAssertEqual(
            query?.first { $0.name == "includeGuids" }?.value,
            "1"
        )
        // `includeFields` is an ALLOW-LIST: asking Plex to inline `Guid` while
        // omitting it from the whitelist silently drops it again.
        let fields = query?.first { $0.name == "includeFields" }?.value ?? ""
        XCTAssertTrue(
            fields.split(separator: ",").contains("Guid"),
            "includeFields must name Guid, or includeGuids is dropped: \(fields)"
        )
    }

    /// The external ids Plex returns have to reach the mapped item, or the
    /// watchlist entry still can't say what the title is.
    func testWatchlistCarriesExternalIDsOntoItems() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"g1","type":"movie","title":"Dune","year":2021,
           "guid":"plex://movie/5d776b9a",
           "Guid":[{"id":"imdb://tt1160419"},{"id":"tmdb://438631"}]}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()

        // Through the same accessor `PlexWatchlistDestination` uses to build the
        // entry's external ids — asserting the raw dictionary keys would pass on
        // a value the destination can't actually reach.
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.providerID(.imdb), "tt1160419")
        XCTAssertEqual(item.providerID(.tmdb), "438631")
        XCTAssertEqual(item.providerIDs["PlexGuid"], "plex://movie/5d776b9a")
    }

    /// The LIBRARY scan must ask for external ids too — it does so through the
    /// shared `containerQuery` helper rather than at this call site, which is
    /// exactly the kind of thing worth pinning: the identity index scans this
    /// endpoint, and without ids every library item would be indexed by title
    /// and year alone.
    func testLibraryScanAsksForExternalIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/1/all", json: """
        {"MediaContainer":{"size":0,"totalSize":0,"Metadata":[]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        _ = try? await provider.items(
            in: "1",
            kind: .movie,
            page: PageRequest(startIndex: 0, limit: 10, sort: .default)
        )

        let query = stub.queryItems(forPathSuffix: "/library/sections/1/all")
        XCTAssertEqual(
            query?.first { $0.name == "includeGuids" }?.value,
            "1"
        )
    }

    /// Regression: the watchlist read must PAGINATE.
    ///
    /// Plex serves this endpoint in pages, and asked for no particular window it
    /// returns only its own default one — so a 139-title watchlist arrived as
    /// the first 20-odd titles and the rest simply didn't exist as far as Plozz
    /// was concerned. A short page is indistinguishable from a short list, so
    /// nothing surfaced the shortfall.
    func testWatchlistReadsEveryPage() async throws {
        let stub = StubHTTPClient()
        let full = (0..<100).map {
            """
            {"ratingKey":"k\($0)","type":"movie","title":"Film \($0)","year":2020}
            """
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            """
            {"MediaContainer":{"size":100,"totalSize":103,"Metadata":[\(full)]}}
            """,
            """
            {"MediaContainer":{"size":3,"totalSize":103,"Metadata":[
              {"ratingKey":"k100","type":"movie","title":"Film 100","year":2020},
              {"ratingKey":"k101","type":"movie","title":"Film 101","year":2020},
              {"ratingKey":"k102","type":"movie","title":"Film 102","year":2020}
            ]}}
            """
        ])
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()

        XCTAssertEqual(items.count, 103)
        XCTAssertEqual(items.last?.title, "Film 102")
    }

    /// Discover can transiently return a short first window even while reporting
    /// that the watchlist contains many more titles. Treating every short page as
    /// terminal made a large watchlist collapse to four cards until app relaunch.
    func testWatchlistContinuesAfterShortPageWhenTotalReportsMore() async throws {
        let stub = StubHTTPClient()
        let remainder = (4..<104).map {
            """
            {"ratingKey":"k\($0)","type":"movie","title":"Film \($0)","year":2020}
            """
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            """
            {"MediaContainer":{"size":4,"totalSize":104,"Metadata":[
              {"ratingKey":"k0","type":"movie","title":"Film 0","year":2020},
              {"ratingKey":"k1","type":"movie","title":"Film 1","year":2020},
              {"ratingKey":"k2","type":"movie","title":"Film 2","year":2020},
              {"ratingKey":"k3","type":"movie","title":"Film 3","year":2020}
            ]}}
            """,
            """
            {"MediaContainer":{"size":100,"totalSize":104,"Metadata":[\(remainder)]}}
            """
        ])

        let items = try await PlexProvider(
            session: makeSession(),
            http: stub
        ).watchlist()

        XCTAssertEqual(items.count, 104)
        XCTAssertEqual(items.last?.title, "Film 103")
        XCTAssertEqual(
            stub.sentQueryItems.compactMap {
                $0.first { $0.name == "X-Plex-Container-Start" }?.value
            },
            ["0", "4"]
        )
    }

    /// A later empty page cannot turn a partial read into authoritative success
    /// while the service still reports unseen titles.
    func testWatchlistRejectsIncompleteEmptyPage() async throws {
        let stub = StubHTTPClient()
        let firstPage = (0..<100).map {
            """
            {"ratingKey":"k\($0)","type":"movie","title":"Film \($0)","year":2020}
            """
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            """
            {"MediaContainer":{"size":100,"totalSize":500,"Metadata":[\(firstPage)]}}
            """,
            """
            {"MediaContainer":{"size":0,"totalSize":500,"Metadata":[]}}
            """
        ])

        do {
            _ = try await PlexProvider(
                session: makeSession(),
                http: stub
            ).watchlist()
            XCTFail("Expected an incomplete response to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
    }

    /// The request cap is a safety boundary, not permission to publish a list the
    /// service itself says is incomplete.
    func testWatchlistRejectsIncompleteReadAtRequestCap() async throws {
        let stub = StubHTTPClient()
        let pages = (0..<100).map { page in
            let start = page * 4
            let items = (start..<(start + 4)).map {
                """
                {"ratingKey":"k\($0)","type":"movie","title":"Film \($0)","year":2020}
                """
            }.joined(separator: ",")
            return """
            {"MediaContainer":{"size":4,"totalSize":500,"Metadata":[\(items)]}}
            """
        }
        stub.stubSequence(
            pathSuffix: "/library/sections/watchlist/all",
            jsons: pages
        )

        do {
            _ = try await PlexProvider(
                session: makeSession(),
                http: stub
            ).watchlist()
            XCTFail("Expected a capped partial response to fail")
        } catch {
            XCTAssertEqual(error as? AppError, .invalidResponse)
        }
        XCTAssertEqual(stub.sentPaths.count, 100)
    }

    func testWatchlistWriteUsesDiscoverHost() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        var item = MediaItem(id: "101", title: "m", kind: .movie)
        item.providerIDs = ["PlexGuid": "plex://movie/abc123"]

        try await provider.setWatchlisted(true, item: item)

        let host = stub.baseURL(forPathSuffix: "/actions/addToWatchlist")?.host
        XCTAssertEqual(host, "discover.provider.plex.tv")
    }

    /// Regression: the Discover watchlist serializes `Media`/`Part`/`Stream` ids
    /// as **strings** (global ids), unlike the PMS API's integers. One string id
    /// must not abort the decode of the whole payload (previously it threw
    /// `typeMismatch: Expected Int … found a string`, yielding an empty row).
    func testWatchlistDecodesDiscoverStringPartIDs() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"librarySectionID":"watchlist","totalSize":2,"size":2,"Metadata":[
          {"ratingKey":"g1","type":"movie","title":"Dune","year":2021,
           "Media":[{"id":"m-abc","Part":[{"id":"p-xyz","Stream":[{"id":"s-1"}]}]}]},
          {"ratingKey":"g2","type":"show","title":"Severance"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        let items = try await provider.watchlist()

        XCTAssertEqual(items.map(\.title), ["Dune", "Severance"])
        XCTAssertTrue(items.allSatisfy(\.isFavorite))
    }

    func testUniversalDestinationResolvesPlexGuidButNeverTitleOrExternalSearch() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/addToWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )
        var item = MediaItem(id: "local", title: "Dune", kind: .movie)
        item.providerIDs["PlexGuid"] = "plex://movie/abc123"
        let alias = MediaAliasID()
        let resolved = try await destination.resolve(
            WatchlistMutationTarget(aliasID: alias, item: item)!
        )
        let binding = try XCTUnwrap(resolved)
        try await destination.apply(.present, to: binding)
        XCTAssertEqual(
            stub.method(forPathSuffix: "/actions/addToWatchlist"),
            .put
        )

        let unresolved = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            externalIDs: [
                WatchlistExternalID(namespace: .imdb, value: "tt1160419")!
            ]
        )!
        let unresolvedBinding = try await destination.resolve(unresolved)
        XCTAssertNil(unresolvedBinding)
    }

    func testHomeUserTokenChangeInvalidatesDestinationScope() throws {
        let token = MutablePlexDiscoverToken("home-user-a")
        let provider = PlexProvider(session: makeSession())
        let destination = try XCTUnwrap(PlexWatchlistDestination(
            provider: provider,
            requiresHomeUserToken: true,
            reconciliationScope: "profile#home-user",
            discoverToken: { token.value }
        ))
        let firstScope = destination.reconciliationScope
        let cacheScope = destination.cacheIdentityScope

        token.value = "home-user-b"

        XCTAssertNotEqual(destination.reconciliationScope, firstScope)
        XCTAssertEqual(destination.cacheIdentityScope, cacheScope)
    }

    func testUniversalDestinationImportProducesCorroboratedAliasEvidence() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"abc123","type":"movie","title":"Dune","year":2021,
           "guid":"plex://movie/abc123","Guid":[{"id":"imdb://tt1160419"}]}
        ]}}
        """)
        let provider = PlexProvider(
            session: makeSession(),
            accountID: "plex-account",
            http: stub
        )
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )

        let imported = try await destination.fetchEntries()
        let entry = try XCTUnwrap(imported.first)
        let evidence = try XCTUnwrap(entry.mediaAliasEvidence)

        XCTAssertEqual(entry.presentationAccountID, "plex-account")
        XCTAssertEqual(evidence.strong.first?.value, "tt1160419")
        XCTAssertEqual(
            evidence.locallyValidatedBindings.first?.providerItemID,
            "abc123"
        )
        let rebound = WatchlistMutationTarget(
            aliasID: MediaAliasID(),
            kind: .movie,
            validatedBindings: Array(evidence.locallyValidatedBindings)
        )!
        let reboundResolution = try await destination.resolve(rebound)
        XCTAssertNotNil(reboundResolution)
    }

    private final class MutablePlexDiscoverToken: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: String

        init(_ value: String) {
            storedValue = value
        }

        var value: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedValue
            }
            set {
                lock.lock()
                storedValue = newValue
                lock.unlock()
            }
        }
    }

    /// Regression — the reported bug: **removing a TV SHOW from the Plex
    /// watchlist did nothing while removing a movie worked.**
    ///
    /// A series page fronts its hero on the episode Play would run, so the
    /// bookmark's subject is the show *promoted* from that episode — an item that
    /// carries no ids of its own. Everything downstream of that promotion has to
    /// keep working on a show exactly as it does on a film: the show's global
    /// `plex://show/<id>` guid is the account-level list's key, and a removal must
    /// address `removeFromWatchlist` with it. A movie was never affected because a
    /// movie hero already IS the movie.
    func testUniversalDestinationRemovesSeriesUsingShowGuid() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/removeFromWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )
        var show = MediaItem(id: "local-show", title: "Andor", kind: .series)
        show.providerIDs["PlexGuid"] = "plex://show/5d9c0874"

        let resolved = try await destination.resolve(
            WatchlistMutationTarget(aliasID: MediaAliasID(), item: show)!
        )
        let binding = try XCTUnwrap(resolved)
        XCTAssertEqual(binding.opaqueValue, "5d9c0874")
        try await destination.apply(.absent, to: binding)

        XCTAssertEqual(
            stub.method(forPathSuffix: "/actions/removeFromWatchlist"),
            .put
        )
        let query = stub.queryItems(forPathSuffix: "/actions/removeFromWatchlist") ?? []
        XCTAssertTrue(query.contains { $0.name == "ratingKey" && $0.value == "5d9c0874" })
        XCTAssertEqual(
            stub.baseURL(forPathSuffix: "/actions/removeFromWatchlist")?.host,
            "discover.provider.plex.tv"
        )
    }

    /// Regression: a mutation target assembled from the **ledger record** — all a
    /// promoted series subject has, since it carries no provider ids itself — must
    /// keep the `plexGuid`. It was dropped on the way out of the record, so such a
    /// target resolved to nothing on Plex and its removal was discarded as an
    /// unsupported identity: the confirmation appeared, the show stayed.
    func testMutationTargetKeepsPlexGuidFromAliasRecord() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/actions/removeFromWatchlist", json: "{}")
        let provider = PlexProvider(session: makeSession(), http: stub)
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )
        let record = try XCTUnwrap(
            MediaAliasRecord(
                kind: .series,
                strongEvidence: [
                    MediaAliasStrongEvidence(
                        kind: .series,
                        namespace: .plexGuid,
                        value: "plex://show/5d9c0874"
                    )!
                ]
            )
        )
        let target = try XCTUnwrap(
            WatchlistMutationTarget(aliasID: record.id, aliasRecord: record)
        )
        XCTAssertTrue(target.externalIDs.contains {
            $0.namespace == .plex && $0.value == "plex://show/5d9c0874"
        })

        let resolved = try await destination.resolve(target)
        let binding = try XCTUnwrap(resolved)
        XCTAssertEqual(binding.opaqueValue, "5d9c0874")
        try await destination.apply(.absent, to: binding)

        let query = stub.queryItems(forPathSuffix: "/actions/removeFromWatchlist") ?? []
        XCTAssertTrue(query.contains { $0.name == "ratingKey" && $0.value == "5d9c0874" })
    }

    /// A show only ever seen through the watchlist READ has no guid of its own on
    /// the target — just the binding the import corroborated. Removal must still
    /// address the Discover id, not fall through to "unsupported identity".
    func testUniversalDestinationRemovesSeriesFromCorroboratedBinding() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/sections/watchlist/all", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"5d9c0874","type":"show","title":"Andor","year":2022,
           "guid":"plex://show/5d9c0874","Guid":[{"id":"tvdb://371980"}]}
        ]}}
        """)
        stub.stub(pathSuffix: "/actions/removeFromWatchlist", json: "{}")
        let provider = PlexProvider(
            session: makeSession(),
            accountID: "plex-account",
            http: stub
        )
        let destination = try XCTUnwrap(
            PlexWatchlistDestination(provider: provider)
        )

        let entries = try await destination.fetchEntries()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.kind, .series)
        let evidence = try XCTUnwrap(entry.mediaAliasEvidence)
        let target = try XCTUnwrap(
            WatchlistMutationTarget(
                aliasID: MediaAliasID(),
                kind: .series,
                validatedBindings: Array(evidence.locallyValidatedBindings)
            )
        )

        let resolvedBinding = try await destination.resolve(target)
        let binding = try XCTUnwrap(resolvedBinding)
        XCTAssertEqual(binding.opaqueValue, "5d9c0874")
        try await destination.apply(.absent, to: binding)

        let query = stub.queryItems(forPathSuffix: "/actions/removeFromWatchlist") ?? []
        XCTAssertTrue(query.contains { $0.name == "ratingKey" && $0.value == "5d9c0874" })
    }

    func testDiscoverDetailRemainsUnownedDespiteAccountOrigin() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/library/metadata/abc123", json: """
        {"MediaContainer":{"size":1,"Metadata":[
          {"ratingKey":"abc123","type":"movie","title":"The Legend of Hei",
           "guid":"plex://movie/abc123"}
        ]}}
        """)
        let provider = PlexProvider(session: makeSession(), http: stub)

        var item = try await provider.item(id: "abc123")
        item.sourceAccountID = "plex-account"

        XCTAssertFalse(item.locallyValidatedPlayableSource)
        XCTAssertFalse(item.hasPlayableLibraryTarget())
    }
}

/// Covers the order the watchlist is asked for.
///
/// The row was arriving in an order that matched neither when titles were added
/// nor one read to the next — "seemingly random when I open the app". Nothing
/// downstream shuffles it: the union preserves each destination's own list
/// position, and that position is the order this read returned. So an unordered
/// read is an unordered row, and asking for no order was the whole of it.
final class PlexWatchlistOrderTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    private func sortValue(_ stub: StubHTTPClient) -> String? {
        stub.queryItems(forPathSuffix: "/library/sections/watchlist/all")?
            .first { $0.name == "sort" }?
            .value
    }

    func testTheReadAsksForWatchlistOrderNewestFirst() async throws {
        let stub = StubHTTPClient()
        stub.stub(
            pathSuffix: "/library/sections/watchlist/all",
            json: #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"k1","type":"movie","title":"A","year":2020}]}}"#
        )

        _ = try await PlexProvider(session: makeSession(), http: stub).watchlist()

        XCTAssertEqual(
            sortValue(stub),
            "watchlistedAt:desc",
            "watchlistedAt is when the title was watchlisted; addedAt answers a different question — when it reached a library"
        )
    }

    /// The order returned is the order presented, so it must survive the read
    /// exactly rather than being re-sorted on some other key.
    func testTheReturnedOrderIsPreserved() async throws {
        let stub = StubHTTPClient()
        stub.stub(
            pathSuffix: "/library/sections/watchlist/all",
            json: """
            {"MediaContainer":{"size":3,"totalSize":3,"Metadata":[
              {"ratingKey":"k1","type":"movie","title":"Newest","year":2024},
              {"ratingKey":"k2","type":"movie","title":"Middle","year":2022},
              {"ratingKey":"k3","type":"movie","title":"Oldest","year":2020}
            ]}}
            """
        )

        let items = try await PlexProvider(session: makeSession(), http: stub).watchlist()

        XCTAssertEqual(items.map(\.title), ["Newest", "Middle", "Oldest"])
    }

    /// These endpoints are undocumented and change without notice. A sort the
    /// service refuses must cost the ordering, never the watchlist.
    func testARefusedSortFallsBackToAnUnorderedReadRatherThanFailing() async throws {
        let stub = StubHTTPClient()
        // First attempt (with the sort) fails; the retry without it succeeds.
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            "{}",
            #"{"MediaContainer":{"size":1,"totalSize":1,"Metadata":[{"ratingKey":"k1","type":"movie","title":"Kept","year":2020}]}}"#
        ])

        let items = try await PlexProvider(session: makeSession(), http: stub).watchlist()

        XCTAssertEqual(items.map(\.title), ["Kept"], "An unordered watchlist beats no watchlist")
        XCTAssertNil(sortValue(stub), "The retry drops the sort rather than sending an empty one")
    }
}

/// A paged watchlist read must not splice two orderings together.
///
/// An offset only means anything within one ordering, so continuing unsorted from
/// where a sorted read left off repeats some titles and silently loses others.
final class PlexWatchlistSortFallbackPagingTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "srv", name: "Home", baseURL: URL(string: "https://plex.host:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testARefusedSortRestartsTheReadRatherThanResumingIt() async throws {
        let stub = StubHTTPClient()
        let firstPage = (0..<100).map {
            #"{"ratingKey":"k\#($0)","type":"movie","title":"Film \#($0)","year":2020}"#
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            // Page 1 sorted, then the service refuses page 2's sort.
            "{\"MediaContainer\":{\"size\":100,\"totalSize\":102,\"Metadata\":[\(firstPage)]}}",
            "{}",
            // The restart: both pages again, unsorted.
            "{\"MediaContainer\":{\"size\":100,\"totalSize\":102,\"Metadata\":[\(firstPage)]}}",
            #"""
            {"MediaContainer":{"size":2,"totalSize":102,"Metadata":[
              {"ratingKey":"k100","type":"movie","title":"Film 100","year":2020},
              {"ratingKey":"k101","type":"movie","title":"Film 101","year":2020}
            ]}}
            """#
        ])

        let items = try await PlexProvider(session: makeSession(), http: stub).watchlist()

        XCTAssertEqual(items.count, 102, "Every title exactly once — no page banked under the old ordering")
        XCTAssertEqual(Set(items.map(\.id)).count, 102, "and none of them duplicated")
    }

    func testSortFallbackResetsTheAbandonedReadTotal() async throws {
        let stub = StubHTTPClient()
        let firstPage = (0..<100).map {
            #"{"ratingKey":"k\#($0)","type":"movie","title":"Film \#($0)","year":2020}"#
        }.joined(separator: ",")
        stub.stubSequence(pathSuffix: "/library/sections/watchlist/all", jsons: [
            "{\"MediaContainer\":{\"size\":100,\"totalSize\":500,\"Metadata\":[\(firstPage)]}}",
            "{}",
            #"""
            {"MediaContainer":{"size":4,"totalSize":4,"Metadata":[
              {"ratingKey":"u0","type":"movie","title":"Unsorted 0","year":2020},
              {"ratingKey":"u1","type":"movie","title":"Unsorted 1","year":2020},
              {"ratingKey":"u2","type":"movie","title":"Unsorted 2","year":2020},
              {"ratingKey":"u3","type":"movie","title":"Unsorted 3","year":2020}
            ]}}
            """#
        ])

        let items = try await PlexProvider(
            session: makeSession(),
            http: stub
        ).watchlist()

        XCTAssertEqual(
            items.map(\.title),
            ["Unsorted 0", "Unsorted 1", "Unsorted 2", "Unsorted 3"]
        )
        XCTAssertEqual(stub.sentPaths.count, 3)
    }
}
