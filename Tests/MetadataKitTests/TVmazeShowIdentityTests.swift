import XCTest
import CoreModels
@testable import MetadataKit

/// Coverage for the guard that stops a TVmaze title search binding the wrong show.
///
/// TVmaze's id lookup covers only part of its catalogue, so most resolves fall back
/// to `singlesearch`, which matches on the title alone — no year, no ids. Two real
/// shows answer to "Lucky": a 2022 documentary that ended, and a 2026 drama airing
/// weekly. Taking the wrong one puts a live schedule on a finished series.
final class TVmazeShowIdentityTests: XCTestCase {

    private func identity(imdb: String? = nil, tvdb: String? = nil) -> TVmazeClient.ShowIdentity {
        TVmazeClient.ShowIdentity(imdb: imdb, tvdb: tvdb)
    }

    // MARK: Conflicting ids

    func testRejectsASameTitledShowWithADifferentTVDBID() {
        // "Lucky!" (2022, tvdb 427619) vs "Lucky" (2026, tvdb 457437).
        XCTAssertFalse(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "tt34866681",
            candidateTVDB: 457437,
            known: identity(imdb: "tt14527704", tvdb: "427619")
        ))
    }

    func testRejectsOnAnIMDbConflictAloneWhenNoTVDBIDIsKnown() {
        XCTAssertFalse(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "tt34866681",
            candidateTVDB: nil,
            known: identity(imdb: "tt14527704")
        ))
    }

    // MARK: Corroborated and uncorroborated matches

    func testAcceptsWhenTheIDsAgree() {
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "TT14527704",
            candidateTVDB: 427619,
            known: identity(imdb: "tt14527704", tvdb: "427619")
        ))
    }

    func testAcceptsACandidateTVmazeCannotCorroborate() {
        // An absent cross-reference is not evidence of a mismatch: TVmaze simply
        // doesn't map every show, and rejecting those would lose real schedules.
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: nil,
            candidateTVDB: nil,
            known: identity(imdb: "tt14527704", tvdb: "427619")
        ))
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "",
            candidateTVDB: nil,
            known: identity(imdb: "tt14527704")
        ))
    }

    func testAcceptsWhenTheQueryCarriesNoIDsAtAll() {
        // Nothing to contradict, so the title match stands — the behaviour a share
        // or an unmatched library item depends on.
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "tt34866681",
            candidateTVDB: 457437,
            known: identity()
        ))
    }

    // MARK: Which ids describe the *show*

    func testAnEpisodeReadsItsSeriesIDsRatherThanItsOwn() {
        // An episode's own Imdb/Tvdb identify that episode. Comparing them against a
        // show's ids would reject every candidate, so the series-scoped ids are used.
        let query = MetadataQuery(
            contentType: .tvShow,
            kind: .episode,
            title: "Silo",
            alternateTitle: nil,
            year: nil,
            seasonNumber: 2,
            episodeNumber: 3,
            animeIDs: AnimeIDs(),
            providerIDs: [
                "Imdb": "tt21123456",
                "SeriesImdb": "tt14688458",
                "SeriesTvdb": "400458",
            ]
        )
        XCTAssertEqual(
            TVmazeClient.showIdentity(for: query),
            identity(imdb: "tt14688458", tvdb: "400458")
        )
    }

    func testASeriesReadsItsOwnIDs() {
        let query = MetadataQuery(
            contentType: .tvShow,
            kind: .series,
            title: "Lucky!",
            alternateTitle: nil,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: AnimeIDs(),
            providerIDs: ["Imdb": "tt14527704", "Tvdb": "427619"]
        )
        XCTAssertEqual(
            TVmazeClient.showIdentity(for: query),
            identity(imdb: "tt14527704", tvdb: "427619")
        )
    }
    // MARK: Ill-formed ids

    func testASlugTVDBIDIsIgnoredRatherThanTreatedAsAConflict() {
        // Some servers store a slug where an id is expected. It can never equal
        // TVmaze's integer, so comparing them would disable TVmaze for that library.
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: nil,
            candidateTVDB: 457437,
            known: identity(tvdb: "lucky")
        ))
    }

    func testANonIMDbShapedIDIsIgnored() {
        XCTAssertTrue(TVmazeClient.isConsistentIdentity(
            candidateIMDb: "tt34866681",
            candidateTVDB: nil,
            known: identity(imdb: "plex://show/5d9c08fd")
        ))
    }

    // MARK: Exact lookups

    func testPrefersAnExactIDLookupOverATitleSearch() {
        // An id settles identity outright, so a title search is never reached when
        // one is known. TVmaze answers with a 301 to the show, which URLSession
        // follows.
        let urls = TVmazeClient.lookupURLs(for: identity(imdb: "tt14527704", tvdb: "427619"))
            .map(\.absoluteString)
        XCTAssertEqual(urls, [
            "https://api.tvmaze.com/lookup/shows?imdb=tt14527704",
            "https://api.tvmaze.com/lookup/shows?thetvdb=427619",
        ])
    }

    func testSkipsLookupsForIDsThatCannotResolve() {
        // A slug or a server's internal id would 404 and cost a request each.
        XCTAssertEqual(
            TVmazeClient.lookupURLs(for: identity(imdb: "plex://show/5d9c", tvdb: "lucky")),
            []
        )
        XCTAssertEqual(TVmazeClient.lookupURLs(for: identity()), [])
    }

}
