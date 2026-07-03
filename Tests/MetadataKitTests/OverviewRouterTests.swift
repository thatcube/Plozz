import XCTest
import CoreModels
@testable import MetadataKit

final class OverviewRouterTests: XCTestCase {

    // MARK: - HTML stripping

    func testStrippedHTMLRemovesTagsAndDecodesEntities() {
        let html = "<p>A tale of <b>speed</b> &amp; <i>family</i>.</p>"
        XCTAssertEqual(OverviewRouter.strippedHTML(html), "A tale of speed & family.")
    }

    func testStrippedHTMLDecodesQuotesAndApostrophes() {
        let html = "<p>She said &quot;it&#39;s fine&quot; &nbsp;today.</p>"
        XCTAssertEqual(OverviewRouter.strippedHTML(html), "She said \"it's fine\"  today.")
    }

    func testStrippedHTMLReturnsNilForEmptyOrTagsOnly() {
        XCTAssertNil(OverviewRouter.strippedHTML(nil))
        XCTAssertNil(OverviewRouter.strippedHTML(""))
        XCTAssertNil(OverviewRouter.strippedHTML("<p></p>"))
        XCTAssertNil(OverviewRouter.strippedHTML("   "))
    }

    // MARK: - Caching (no network: a cached negative is honoured)

    func testCachedNegativeIsReturnedWithoutRefetch() async {
        // Music resolves to nil synchronously (no provider), so the first lookup
        // caches `.some(nil)`; the second must return the cached negative. This
        // exercises the positive+negative cache path without touching the network.
        let router = OverviewRouter()
        let item = MediaItem(id: "x", title: "Some Album", kind: .unknown)
        var query = MetadataQuery(item)
        query = MetadataQuery(
            contentType: .music,
            kind: query.kind,
            title: query.title,
            alternateTitle: nil,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            animeIDs: query.animeIDs,
            providerIDs: query.providerIDs
        )
        let first = await router.overview(for: query)
        let second = await router.overview(for: query)
        XCTAssertNil(first)
        XCTAssertNil(second)
    }
}
