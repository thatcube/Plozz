import XCTest
import CoreModels
@testable import RatingsService

/// Lookup-strategy tests for ``TMDbRatingsProvider``.
///
/// These cover the decisions made *before* any request goes out — which is the
/// part that decides whether a title gets a rating at all, and the part a live
/// API can't tell you is wrong. A bad lookup doesn't error; it silently returns
/// somebody else's score.
final class TMDbRatingsProviderTests: XCTestCase {
    private func item(
        kind: MediaItemKind,
        title: String = "The Bad Guys 2",
        parentTitle: String? = nil,
        year: Int? = nil,
        providerIDs: [String: String] = [:]
    ) -> MediaItem {
        MediaItem(
            id: "1",
            title: title,
            kind: kind,
            parentTitle: parentTitle,
            productionYear: year,
            providerIDs: providerIDs
        )
    }

    func testPrefersStampedTMDbIDOverSearch() {
        let lookup = TMDbRatingsProvider.lookup(
            for: item(kind: .movie, providerIDs: ["Tmdb": "1175942"])
        )
        guard case let .id(id, kind) = lookup else {
            return XCTFail("expected a direct id lookup, got \(String(describing: lookup))")
        }
        XCTAssertEqual(id, "1175942")
        XCTAssertEqual(kind, .movie)
    }

    func testProviderIDLookupIsCaseInsensitive() {
        // Jellyfin sends "Tmdb", Plex sends "tmdb" — both must resolve.
        for key in ["Tmdb", "tmdb", "TMDB"] {
            let lookup = TMDbRatingsProvider.lookup(
                for: item(kind: .movie, providerIDs: [key: "27205"])
            )
            guard case let .id(id, _) = lookup else {
                return XCTFail("\(key) did not resolve to an id lookup")
            }
            XCTAssertEqual(id, "27205")
        }
    }

    func testNonNumericProviderIDFallsBackToSearch() {
        // A malformed id would 404 and waste the request, so it must not be used.
        let lookup = TMDbRatingsProvider.lookup(
            for: item(kind: .movie, providerIDs: ["Tmdb": "not-an-id"])
        )
        guard case .search = lookup else {
            return XCTFail("expected search fallback, got \(String(describing: lookup))")
        }
    }

    func testMovieSearchCorroboratesWithYear() {
        let lookup = TMDbRatingsProvider.lookup(for: item(kind: .movie, year: 2025))
        guard case let .search(title, year, kind) = lookup else {
            return XCTFail("expected a search lookup")
        }
        XCTAssertEqual(title, "The Bad Guys 2")
        XCTAssertEqual(year, 2025)
        XCTAssertEqual(kind, .movie)
    }

    func testSeriesSearchOmitsYear() {
        // A series' productionYear is often the *season's*, which would filter
        // out the correct show entirely.
        let lookup = TMDbRatingsProvider.lookup(
            for: item(kind: .series, title: "Severance", year: 2025)
        )
        guard case let .search(_, year, kind) = lookup else {
            return XCTFail("expected a search lookup")
        }
        XCTAssertNil(year)
        XCTAssertEqual(kind, .tv)
    }

    func testEpisodesAndSeasonsGetNoRating() {
        // Jellyfin scopes its own CommunityRating to the individual episode, so a
        // series-level TMDb score on the same page would sit in an identical tile
        // while describing something else entirely. Better to show nothing than
        // to silently mix scopes.
        for kind in [MediaItemKind.episode, .season] {
            XCTAssertNil(
                TMDbRatingsProvider.lookup(
                    for: item(
                        kind: kind,
                        title: "Good News About Hell",
                        parentTitle: "Severance",
                        providerIDs: ["Tmdb": "95396"]
                    )
                ),
                "\(kind) must not borrow the series' score"
            )
        }
    }

    func testUnsupportedKindsAreSkippedEntirely() {
        // A folder or collection has no TMDb equivalent, and a loose video file
        // has no reliable title to match on — a lookup would be a wasted request
        // that can only ever return a wrong match.
        for kind in [MediaItemKind.folder, .collection, .video, .unknown] {
            XCTAssertNil(
                TMDbRatingsProvider.lookup(for: item(kind: kind)),
                "\(kind) should not produce a TMDb lookup"
            )
        }
    }

    func testBlankTitleWithNoIDProducesNoLookup() {
        XCTAssertNil(TMDbRatingsProvider.lookup(for: item(kind: .movie, title: "   ")))
    }

    func testYearParameterDiffersByKind() {
        // TMDb silently ignores the wrong year parameter rather than rejecting
        // it, which would return an unfiltered first match.
        XCTAssertEqual(TMDbRatingsProvider.Kind.movie.yearParameter, "year")
        XCTAssertEqual(TMDbRatingsProvider.Kind.tv.yearParameter, "first_air_date_year")
    }
}
