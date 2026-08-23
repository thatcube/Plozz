import CoreModels
import XCTest
@testable import FeatureHomeCore

/// The hero re-curates constantly for reasons the viewer never asked for. These
/// pin down what a re-curation is allowed to do to what is already on screen.
final class HeroLiveMergeTests: XCTestCase {
    private func item(
        _ id: String,
        title: String? = nil,
        kind: MediaItemKind = .movie,
        year: Int? = nil,
        account: String? = nil,
        overview: String? = nil,
        backdrop: String? = "https://example.com/art.jpg"
    ) -> MediaItem {
        MediaItem(
            id: id,
            title: title ?? id,
            kind: kind,
            overview: overview,
            productionYear: year,
            backdropURL: backdrop.flatMap(URL.init(string:)),
            sourceAccountID: account
        )
    }

    // MARK: - Nothing on screen yet

    func testFirstCurationIsAdoptedWhole() {
        let fresh = [item("a"), item("b")]

        let merged = HeroLiveMerge.merge(showing: [], fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.admitted, ["a", "b"])
        XCTAssertTrue(merged.retired.isEmpty)
    }

    func testFirstCurationStillRespectsTheCarouselSize() {
        let fresh = (1...5).map { item("i\($0)") }

        let merged = HeroLiveMerge.merge(showing: [], fresh: fresh, limit: 3)

        XCTAssertEqual(merged.items.map(\.id), ["i1", "i2", "i3"])
    }

    // MARK: - A refresh must never blank or reshuffle what is showing

    func testFailedRefreshLeavesTheCarouselAlone() {
        let showing = [item("a"), item("b")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: [], limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b"])
        XCTAssertFalse(merged.changedIdentitySet)
    }

    func testReorderedCurationDoesNotReorderTheCarousel() {
        let showing = [item("a"), item("b"), item("c")]
        let fresh = [item("c"), item("a"), item("b")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(merged.changedIdentitySet)
    }

    func testATitleTheFreshCurationNoLongerOffersIsKept() {
        // A Random re-roll not picking something again is not evidence it is
        // gone, and the viewer could already browse to it.
        let showing = [item("a"), item("dropped"), item("b")]
        let fresh = [item("a"), item("b")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "dropped", "b"])
        XCTAssertFalse(merged.changedIdentitySet)
    }

    // MARK: - Fresh data still lands

    func testARetainedSlotTakesTheFresherPayloadWithoutMoving() {
        let showing = [item("a", overview: nil), item("b")]
        let fresh = [item("a", overview: "now enriched"), item("b")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.items.first?.overview, "now enriched")
        XCTAssertFalse(merged.changedIdentitySet)
    }

    func testARetainedSlotKeepsArtworkTheFreshCopyLacks() {
        let showing = [item("a", backdrop: "https://example.com/resolved.jpg")]
        let fresh = [item("a", backdrop: nil)]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(
            merged.items.first?.backdropURL?.absoluteString,
            "https://example.com/resolved.jpg"
        )
    }

    func testASlideFollowsItsShowToTheNextEpisodeInPlace() {
        // Continue Watching moving on is the fresh truth. Keeping the old id here
        // would leave the hero offering an episode the viewer already finished.
        var watched = item("ep-1", title: "Chapter One", kind: .episode)
        watched.seriesID = "show-9"
        watched.parentTitle = "The Show"
        var next = item("ep-2", title: "Chapter Two", kind: .episode)
        next.seriesID = "show-9"
        next.parentTitle = "The Show"

        let merged = HeroLiveMerge.merge(
            showing: [item("a"), watched],
            fresh: [item("a"), next],
            limit: 8
        )

        XCTAssertEqual(merged.items.map(\.id), ["a", "ep-2"])
        XCTAssertTrue(merged.retired.isEmpty)
        XCTAssertTrue(merged.admitted.isEmpty)
    }

    func testACrossServerPromotionTakesTheServerThatCanServeIt() {
        let showing = [
            item("server-1-id", title: "Arrival", year: 2016, account: "one")
        ]
        let fresh = [
            item(
                "server-2-id",
                title: "Arrival",
                year: 2016,
                account: "two",
                overview: "fuller record"
            )
        ]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["server-2-id"])
        XCTAssertEqual(merged.items.first?.overview, "fuller record")
    }

    // MARK: - New media gets in

    func testNewMediaTakesSpareCapacityWithoutDisplacingAnything() {
        let showing = [item("a"), item("b")]
        let fresh = [item("a"), item("b"), item("new")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 8)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b", "new"])
        XCTAssertEqual(merged.admitted, ["new"])
        XCTAssertTrue(merged.retired.isEmpty)
    }

    func testAFullCarouselAdmitsNewMediaOverItsStalestSlot() {
        let showing = [item("stale"), item("a"), item("b")]
        let fresh = [item("a"), item("b"), item("new")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 3)

        XCTAssertEqual(merged.items.map(\.id), ["new", "a", "b"])
        XCTAssertEqual(merged.admitted, ["new"])
        XCTAssertEqual(merged.retired, ["stale"])
    }

    func testTheSlideTheViewerIsLookingAtIsNeverDisplaced() {
        let showing = [item("watching"), item("stale"), item("a")]
        let fresh = [item("a"), item("new")]

        let merged = HeroLiveMerge.merge(
            showing: showing,
            fresh: fresh,
            limit: 3,
            pinnedItemIDs: ["watching"]
        )

        XCTAssertEqual(merged.items.map(\.id), ["watching", "new", "a"])
        XCTAssertEqual(merged.retired, ["stale"])
    }

    func testNewMediaWaitsWhenOnlyThePinnedSlotCouldMakeRoom() {
        let showing = [item("watching"), item("a")]
        let fresh = [item("a"), item("new")]

        let merged = HeroLiveMerge.merge(
            showing: showing,
            fresh: fresh,
            limit: 2,
            pinnedItemIDs: ["watching"]
        )

        XCTAssertEqual(merged.items.map(\.id), ["watching", "a"])
        XCTAssertTrue(merged.admitted.isEmpty)
        XCTAssertTrue(merged.retired.isEmpty)
    }

    // MARK: - Identity, not raw ids

    func testAResumableEpisodeAndItsSeriesStayOneSlideAcrossARefresh() {
        // One slide per show. The slot survives; which record represents it is the
        // fresh curation's call.
        var episode = item("ep-1", title: "Chapter One", kind: .episode)
        episode.seriesID = "show-9"
        episode.parentTitle = "The Show"
        let series = item("show-9", title: "The Show", kind: .series)

        let merged = HeroLiveMerge.merge(
            showing: [episode],
            fresh: [series],
            limit: 8
        )

        XCTAssertEqual(merged.items.map(\.id), ["show-9"])
        XCTAssertEqual(merged.items.count, 1)
        XCTAssertTrue(merged.admitted.isEmpty)
        XCTAssertTrue(merged.retired.isEmpty)
    }

    func testAnIdentityRevealedAfterCurationCollapsesToOneSlide() {
        // Two slides that enrichment later proves are the same show must not both
        // keep rendering the same backdrop.
        var episode = item("ep-1", title: "Chapter One", kind: .episode)
        episode.seriesID = "show-9"
        episode.parentTitle = "The Show"
        let series = item("show-9", title: "The Show", kind: .series)

        let merged = HeroLiveMerge.merge(
            showing: [series, episode],
            fresh: [series],
            limit: 8
        )

        XCTAssertEqual(merged.items.map(\.id), ["show-9"])
        XCTAssertEqual(merged.retired, ["ep-1"])
    }

    func testACollapseKeepsTheSlideTheViewerIsLookingAt() {
        var episode = item("ep-1", title: "Chapter One", kind: .episode)
        episode.seriesID = "show-9"
        episode.parentTitle = "The Show"
        let series = item("show-9", title: "The Show", kind: .series)

        let merged = HeroLiveMerge.merge(
            showing: [series, episode],
            fresh: [series],
            limit: 8,
            pinnedItemIDs: ["ep-1"]
        )

        XCTAssertEqual(merged.items.map(\.id), ["ep-1"])
        XCTAssertEqual(merged.retired, ["show-9"])
    }

    func testAnAuthoritativelyEmptyCurationClearsTheCarousel() {
        // The viewer hid every library, or watched everything: there is genuinely
        // nothing left, and keeping the old slides would be a lie.
        let merged = HeroLiveMerge.merge(
            showing: [item("a"), item("b")],
            fresh: [],
            limit: 8,
            freshIsAuthoritative: true
        )

        XCTAssertTrue(merged.items.isEmpty)
        XCTAssertEqual(merged.retired, ["a", "b"])
    }

    func testAPinnedSlideKeepsItsRecordUntilTheViewerPagesAway() {
        // Swapping which record the slide on screen is would re-seat the carousel
        // and wipe the backdrop under them.
        var watched = item("ep-1", title: "Chapter One", kind: .episode)
        watched.seriesID = "show-9"
        watched.parentTitle = "The Show"
        var next = item("ep-2", title: "Chapter Two", kind: .episode)
        next.seriesID = "show-9"
        next.parentTitle = "The Show"

        let pinned = HeroLiveMerge.merge(
            showing: [watched],
            fresh: [next],
            limit: 8,
            pinnedItemIDs: ["ep-1"]
        )
        XCTAssertEqual(pinned.items.map(\.id), ["ep-1"])

        let pagedAway = HeroLiveMerge.merge(
            showing: pinned.items,
            fresh: [next],
            limit: 8,
            pinnedItemIDs: ["something-else"]
        )
        XCTAssertEqual(pagedAway.items.map(\.id), ["ep-2"])
    }

    func testAPinnedSlideTakesTheNewerRecordEvenIfTheViewerNeverPagesAway() {
        // The deferral has to converge on its own. It is bounded by a counter that
        // deferring itself must advance — a pinned slot whose fresh counterpart
        // merely differs by id never *misses*, so counting only absences would let
        // it hold a superseded episode for the whole session. That is the case a
        // one-slide carousel, or auto-advance switched off, produces.
        var watched = item("ep-1", title: "Chapter One", kind: .episode)
        watched.seriesID = "show-9"
        watched.parentTitle = "The Show"
        var next = item("ep-2", title: "Chapter Two", kind: .episode)
        next.seriesID = "show-9"
        next.parentTitle = "The Show"

        var showing = [watched]
        var misses: [String: Int] = [:]
        var pinned: Set<String> = ["ep-1"]
        for _ in 0...(HeroLiveMerge.retentionGrace + HeroLiveMerge.pinnedDeferralLimit) {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: [next],
                limit: 1,
                pinnedItemIDs: pinned,
                misses: misses
            )
            showing = merged.items
            misses = merged.misses
            // The viewer never moves: whatever is fronted stays fronted.
            pinned = Set(showing.map(\.id))
        }

        XCTAssertEqual(showing.map(\.id), ["ep-2"])
    }


    // MARK: - Bounded retention

    func testATitleTheCurationStopsOfferingIsRetiredAfterItsGrace() {
        // A removed watchlist entry, a hidden library or deleted media. One miss
        // proves nothing; several in a row do.
        let fresh = [item("a")]
        var showing = [item("a"), item("removed")]
        var misses: [String: Int] = [:]

        for pass in 1..<HeroLiveMerge.retentionGrace {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: fresh,
                limit: 8,
                misses: misses
            )
            XCTAssertEqual(merged.items.map(\.id), ["a", "removed"], "pass \(pass)")
            showing = merged.items
            misses = merged.misses
        }

        let final = HeroLiveMerge.merge(
            showing: showing,
            fresh: fresh,
            limit: 8,
            misses: misses
        )
        XCTAssertEqual(final.items.map(\.id), ["a"])
        XCTAssertEqual(final.retired, ["removed"])
    }

    func testAFailedRefreshDoesNotAgeAnything() {
        // Otherwise a server outage would empty the carousel one grace later.
        var showing = [item("a"), item("b")]
        var misses: [String: Int] = [:]
        for _ in 0...(HeroLiveMerge.retentionGrace + 2) {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: [],
                limit: 8,
                misses: misses
            )
            showing = merged.items
            misses = merged.misses
        }

        XCTAssertEqual(showing.map(\.id), ["a", "b"])
    }

    func testAMissedTitleThatComesBackStopsAging() {
        let showing = [item("a"), item("flaky")]
        let firstMiss = HeroLiveMerge.merge(
            showing: showing,
            fresh: [item("a")],
            limit: 8
        )
        XCTAssertEqual(firstMiss.misses["flaky"], 1)

        let recovered = HeroLiveMerge.merge(
            showing: firstMiss.items,
            fresh: [item("a"), item("flaky")],
            limit: 8,
            misses: firstMiss.misses
        )

        XCTAssertNil(recovered.misses["flaky"])
        XCTAssertEqual(recovered.items.map(\.id), ["a", "flaky"])
    }

    func testTheSlideTheViewerIsLookingAtOutlivesTheOrdinaryGrace() {
        var showing = [item("watching"), item("a")]
        var misses: [String: Int] = [:]
        for _ in 0..<HeroLiveMerge.retentionGrace {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: [item("a")],
                limit: 8,
                pinnedItemIDs: ["watching"],
                misses: misses
            )
            showing = merged.items
            misses = merged.misses
        }

        XCTAssertEqual(showing.map(\.id), ["watching", "a"])
    }

    func testEvenTheFrontedSlideEventuallyGoes() {
        // Pinning cannot be an absolute exemption: a one-slide carousel is always
        // pinned, and with auto-advance off the fronted slide never rotates on its
        // own — so an absolute pin freezes those heroes for the whole session.
        var showing = [item("watching"), item("a")]
        var misses: [String: Int] = [:]
        for _ in 0...(HeroLiveMerge.retentionGrace + HeroLiveMerge.pinnedDeferralLimit) {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: [item("a")],
                limit: 8,
                pinnedItemIDs: ["watching"],
                misses: misses
            )
            showing = merged.items
            misses = merged.misses
        }

        XCTAssertEqual(showing.map(\.id), ["a"])
    }

    func testAOneSlideCarouselStillTakesFreshTitles() {
        // `maxItems` goes down to 1, and that single slot is always the fronted
        // one. It must not pin itself into permanence.
        var showing = [item("stale")]
        var misses: [String: Int] = [:]
        for _ in 0...(HeroLiveMerge.retentionGrace + HeroLiveMerge.pinnedDeferralLimit) {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: [item("fresh")],
                limit: 1,
                pinnedItemIDs: Set(showing.map(\.id)),
                misses: misses
            )
            showing = merged.items
            misses = merged.misses
        }

        XCTAssertEqual(showing.map(\.id), ["fresh"])
    }

    func testASwipeInFlightKeepsBothOfItsSlides() {
        // iOS pins the outgoing slide and the one a committed swipe is landing on.
        // Collapsing either into the other strands the transition.
        var episode = item("ep-1", title: "Chapter One", kind: .episode)
        episode.seriesID = "show-9"
        episode.parentTitle = "The Show"
        let series = item("show-9", title: "The Show", kind: .series)

        let merged = HeroLiveMerge.merge(
            showing: [series, episode],
            fresh: [series],
            limit: 8,
            pinnedItemIDs: ["show-9", "ep-1"]
        )

        XCTAssertEqual(merged.items.map(\.id), ["show-9", "ep-1"])
        XCTAssertTrue(merged.retired.isEmpty)
    }

    func testALoweredCapNeverAdmitsATitleItIsAboutToDrop() {
        // Writing an arrival into a slot the cap then truncates would report it
        // admitted and retired at once, and silently lose the new title.
        let showing = ["a", "b", "c", "d", "e"].map { item($0) }
        let fresh = [item("a"), item("b"), item("c"), item("x")]

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 3)

        XCTAssertEqual(merged.items.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(
            Set(merged.admitted).isDisjoint(with: Set(merged.retired)),
            "an id cannot be both admitted and retired"
        )
        XCTAssertTrue(merged.admitted.isEmpty)
    }

    // MARK: - Bounds

    func testALoweredCarouselSizeTrimsTheCarousel() {
        let showing = (1...5).map { item("i\($0)") }
        let fresh = (1...5).map { item("i\($0)") }

        let merged = HeroLiveMerge.merge(showing: showing, fresh: fresh, limit: 2)

        XCTAssertEqual(merged.items.map(\.id), ["i1", "i2"])
        XCTAssertEqual(merged.retired, ["i3", "i4", "i5"])
    }

    func testAZeroSizedCarouselHoldsNothing() {
        let merged = HeroLiveMerge.merge(
            showing: [item("a")],
            fresh: [item("b")],
            limit: 0
        )

        XCTAssertTrue(merged.items.isEmpty)
    }

    func testRepeatedIdenticalRefreshesNeverDisturbTheCarousel() {
        // The common case with several servers connected: Home republishes over
        // and over, and every one of those recurations must be a no-op.
        let fresh = (1...4).map { item("i\($0)") }
        var showing = fresh
        for _ in 0..<10 {
            let merged = HeroLiveMerge.merge(
                showing: showing,
                fresh: fresh,
                limit: 8
            )
            XCTAssertFalse(merged.changedIdentitySet)
            XCTAssertEqual(merged.items.map(\.id), showing.map(\.id))
            showing = merged.items
        }
    }
}
