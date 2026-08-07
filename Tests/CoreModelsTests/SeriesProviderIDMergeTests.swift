import XCTest
import CoreModels

/// A season's own ids are NOT the series' ids.
///
/// Plex and Jellyfin both return seasons in a show's Recently Added, so a season
/// is what the Home hero is handed for a show. Its `tmdb` identifies that season
/// — Ted Lasso's season row carried 466392 where the series is 97546 — and
/// adopting it as `seriesTmdb` pointed every series-scoped lookup at a season
/// entity. That resolved to no external ids, so TVmaze could never be reached
/// and the hero silently lost its "New episode every Wednesday" line while the
/// detail page, which starts from the series, showed it correctly.
final class SeriesProviderIDMergeTests: XCTestCase {

    func testBaseIDsAreNotPromotedWhenSourceIsNotASeries() {
        var target: [String: String] = [:]
        target.mergeSeriesProviderIDs(
            from: ["Tmdb": "466392"],
            promotingBaseIDs: false
        )
        XCTAssertNil(
            target.providerID(.seriesTmdb),
            "a season's own tmdb must not become the series tmdb"
        )
    }

    func testBaseIDsArePromotedWhenSourceIsASeries() {
        var target: [String: String] = [:]
        target.mergeSeriesProviderIDs(from: ["Tmdb": "97546"])
        XCTAssertEqual(target.providerID(.seriesTmdb), "97546")
    }

    /// Explicit series ids are trustworthy whatever the source's own kind, so
    /// they transfer even when base promotion is refused.
    func testExplicitSeriesIDsTransferEvenWithoutBasePromotion() {
        var target: [String: String] = [:]
        target.mergeSeriesProviderIDs(
            from: ["SeriesTmdb": "97546", "Tmdb": "466392"],
            promotingBaseIDs: false
        )
        XCTAssertEqual(target.providerID(.seriesTmdb), "97546")
    }

    /// The merge fills only what is missing, so whichever source is consulted
    /// FIRST wins. The series must therefore be merged before the original card.
    func testFirstMergeWins() {
        var target: [String: String] = [:]
        target.mergeSeriesProviderIDs(from: ["Tmdb": "97546"])
        target.mergeSeriesProviderIDs(from: ["Tmdb": "466392"])
        XCTAssertEqual(
            target.providerID(.seriesTmdb),
            "97546",
            "the series is merged first, so a later season id cannot displace it"
        )
    }
}
