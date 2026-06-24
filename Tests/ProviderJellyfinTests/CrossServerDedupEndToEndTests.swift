import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin
@testable import ProviderPlex

/// True end-to-end cross-server de-duplication, exercising the *whole* chain on
/// realistic provider payloads — not synthetic injected ids:
///
///   provider request → DTO decode → `providerIDs` map → `MediaItemIdentity`
///   → `MediaItemMerger` → `MediaItem.sources` (what the ItemDetail server
///   picker gates on with `sources.count > 1`).
///
/// A Jellyfin `/search` payload (carrying `ProviderIds`) and a Plex `/search`
/// payload (carrying inlined `Guid`s) for the SAME movie and the SAME series are
/// decoded through the real providers, tagged with their accounts, then merged.
/// Both titles must collapse to a single card exposing both servers.
final class CrossServerDedupEndToEndTests: XCTestCase {
    private let plexAccount = "acct-plex"
    private let jellyAccount = "acct-jelly"

    private func jellyfinProvider() -> JellyfinProvider {
        let stub = StubHTTPClient()
        // Jellyfin search hits /Users/{id}/Items. The same movie + series the Plex
        // server also has, with the external ids the fix now requests.
        stub.stub(pathSuffix: "/Users/u1/Items", json: """
        {"Items":[
          {"Id":"jf-dune","Name":"Dune","Type":"Movie","ProductionYear":2021,
           "ProviderIds":{"Imdb":"tt1160419","Tmdb":"438631"}},
          {"Id":"jf-op","Name":"One Piece","Type":"Series","ProductionYear":1999,
           "ProviderIds":{"Tmdb":"37854","Tvdb":"81797"}}
        ]}
        """)
        let session = UserSession(
            server: MediaServer(id: "jf", name: "Jellyfin Home", baseURL: URL(string: "http://jf:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Bob", deviceID: "d1", accessToken: "T"
        )
        return JellyfinProvider(session: session, http: stub)
    }

    private func plexProvider() -> PlexProvider {
        let stub = StubHTTPClient()
        // Plex search hits /search and inlines Guid arrays (includeGuids=1).
        stub.stub(pathSuffix: "/search", json: """
        {"MediaContainer":{"size":2,"Metadata":[
          {"ratingKey":"plex-dune","type":"movie","title":"Dune","year":2021,
           "Guid":[{"id":"imdb://tt1160419"},{"id":"tmdb://438631"}]},
          {"ratingKey":"plex-op","type":"show","title":"One Piece","year":1999,
           "Guid":[{"id":"tmdb://37854"},{"id":"tvdb://81797"}]}
        ]}}
        """)
        let session = UserSession(
            server: MediaServer(id: "px", name: "Plex Home", baseURL: URL(string: "https://px:32400")!, provider: .plex),
            userID: "u1", userName: "Alice", deviceID: "d2", accessToken: "T"
        )
        return PlexProvider(session: session, http: stub)
    }

    private func serverInfo(_ accountID: String) -> SourceServerInfo? {
        switch accountID {
        case plexAccount: return SourceServerInfo(providerKind: .plex, serverName: "Plex Home", accountName: "Alice")
        case jellyAccount: return SourceServerInfo(providerKind: .jellyfin, serverName: "Jellyfin Home", accountName: "Bob")
        default: return nil
        }
    }

    func testSameMovieAndSeriesAcrossPlexAndJellyfinCollapseWithServerPicker() async throws {
        // Decode both servers' real search payloads through the real providers.
        let plexHits = try await plexProvider().search(query: "x", limit: 25)
            .map { $0.taggingSource(plexAccount) }
        let jellyHits = try await jellyfinProvider().search(query: "x", limit: 25)
            .map { $0.taggingSource(jellyAccount) }

        // Sanity: the providers actually populated external ids from the payloads.
        XCTAssertEqual(plexHits.first(where: { $0.title == "Dune" })?.providerIDs["Imdb"], "tt1160419")
        XCTAssertEqual(jellyHits.first(where: { $0.title == "One Piece" })?.providerIDs["Tmdb"], "37854")

        // Interleave the way Search/Home do (Plex first here) and merge.
        let merged = MediaItemMerger.merge(plexHits + jellyHits, serverInfo: serverInfo)

        // Two distinct titles, each collapsed from two servers into one card.
        XCTAssertEqual(merged.count, 2, "Same movie and same series must each collapse to one card")

        let dune = try XCTUnwrap(merged.first { $0.title == "Dune" })
        XCTAssertEqual(dune.sources.count, 2, "Movie on two servers must expose a 2-source picker")
        XCTAssertEqual(Set(dune.sources.map(\.accountID)), [plexAccount, jellyAccount])
        XCTAssertEqual(dune.providerIDs["Imdb"], "tt1160419")
        XCTAssertEqual(dune.providerIDs["Tmdb"], "438631")

        // The series is the real regression: with empty providerIDs (the old
        // behaviour) a series NEVER merges, because title identity is movies-only.
        let onePiece = try XCTUnwrap(merged.first { $0.title == "One Piece" })
        XCTAssertEqual(onePiece.sources.count, 2, "Series on two servers must collapse via shared external id and expose the picker")
        XCTAssertEqual(Set(onePiece.sources.map(\.accountID)), [plexAccount, jellyAccount])

        // Primary (first-seen = Plex) leads the picker; labels resolve per server.
        XCTAssertEqual(dune.sources.first?.providerKind, .plex)
        XCTAssertEqual(dune.sources.first?.serverName, "Plex Home")
        XCTAssertEqual(dune.sources.last?.providerKind, .jellyfin)
        XCTAssertEqual(dune.sources.map(\.itemID).sorted(), ["jf-dune", "plex-dune"])
    }

    func testWithoutExternalIDsSeriesDoesNotCollapse() async throws {
        // Guards the fix's necessity: strip external ids (the pre-fix payload) and
        // the two One Piece series must stay separate (no unsafe title merge).
        let plex = MediaItem(id: "plex-op", title: "One Piece", kind: .series, productionYear: 1999,
                             sourceAccountID: plexAccount)
        let jelly = MediaItem(id: "jf-op", title: "One Piece", kind: .series, productionYear: 1999,
                              sourceAccountID: jellyAccount)

        let merged = MediaItemMerger.merge([plex, jelly], serverInfo: serverInfo)

        XCTAssertEqual(merged.count, 2, "Series without external ids must never collapse — that is why populating them is the fix")
    }
}
