import XCTest
@testable import CoreModels

/// Coverage for `HeroArtworkPlanner` — the one policy that decides which picture
/// Home shows and which one the detail page shows, for every backend.
///
/// The bug it exists to prevent: both heroes resolved the same single URL, so a
/// title was drawn with the identical image on both screens. The planner's job is
/// to rank a title's wide art and hand the two screens *different* members of it.
final class HeroArtworkPlannerTests: XCTestCase {

    private func ref(_ name: String) -> ArtworkReference {
        .remote(URL(string: "https://art.example/\(name).jpg")!)
    }

    private func candidate(
        _ name: String,
        origin: HeroArtworkOrigin = .server,
        text: HeroArtworkTextPresence = .unknown,
        score: Double = 0
    ) -> HeroArtworkCandidate {
        HeroArtworkCandidate(reference: ref(name), origin: origin, text: text, score: score)
    }

    private func chosen(_ selections: [ArtworkSelection], _ placement: ArtworkPlacement) -> ArtworkReference? {
        selections.first { $0.placement == placement }?.references.first
    }

    // MARK: The guarantee

    /// The whole point: two distinct pictures means two distinct screens.
    func testTheTwoHeroesNeverShareAPictureWhenThereAreTwo() {
        let plan = HeroArtworkPlanner.selections(for: [candidate("a"), candidate("b")])
        let home = chosen(plan, .homeHero)
        let detail = chosen(plan, .detailBackdrop)
        XCTAssertEqual(home, ref("a"))
        XCTAssertEqual(detail, ref("b"))
        XCTAssertNotEqual(home, detail)
    }

    /// Holds across a wide range of pool shapes, not just the two-image case.
    func testDistinctForEveryPoolOfTwoOrMore() {
        let pool = (0..<6).map { candidate("img\($0)", score: Double(6 - $0)) }
        for size in 2...pool.count {
            let plan = HeroArtworkPlanner.selections(for: Array(pool.prefix(size)))
            XCTAssertNotEqual(
                chosen(plan, .homeHero),
                chosen(plan, .detailBackdrop),
                "pool of \(size) put the same picture on both screens"
            )
        }
    }

    /// One picture is a fact about the library, not a decision. Both placements are
    /// still emitted so the caller has one ladder to read.
    func testASinglePictureIsGivenToBothRatherThanInvented() {
        let plan = HeroArtworkPlanner.selections(for: [candidate("only")])
        XCTAssertEqual(chosen(plan, .homeHero), ref("only"))
        XCTAssertEqual(chosen(plan, .detailBackdrop), ref("only"))
    }

    /// The same URL arriving twice is one picture, not two — it must not be allowed
    /// to fill both slots and defeat the guarantee.
    func testADuplicateURLCannotFillBothSlots() {
        let plan = HeroArtworkPlanner.selections(for: [
            candidate("a"),
            candidate("a", origin: .external)
        ])
        XCTAssertEqual(chosen(plan, .homeHero), chosen(plan, .detailBackdrop))
        XCTAssertEqual(plan.first { $0.placement == .homeHero }?.references.count, 1)
    }

    func testAnEmptyPoolSaysNothing() {
        XCTAssertTrue(HeroArtworkPlanner.selections(for: []).isEmpty)
    }

    // MARK: The hierarchy

    /// Textless outranks everything. The hero draws the logo on top, so a backdrop
    /// carrying the title writes the show's name twice.
    func testTextlessArtIsPreferredForHomeEvenAtALowerScore() {
        let plan = HeroArtworkPlanner.selections(for: [
            candidate("titled", text: .titled, score: 100),
            candidate("serverish", text: .unknown, score: 50),
            candidate("clean", text: .textless, score: 0)
        ])
        XCTAssertEqual(chosen(plan, .homeHero), ref("clean"))
    }

    /// A picture known to carry the title sinks below one that merely might.
    func testKnownTitledArtSinksBelowUnknown() {
        let ranked = HeroArtworkPlanner.rank([
            candidate("titled", text: .titled, score: 100),
            candidate("unknown", text: .unknown, score: 0)
        ])
        XCTAssertEqual(ranked.map(\.reference), [ref("unknown"), ref("titled")])
    }

    /// Within a tier the caller's own preference decides.
    func testScoreOrdersWithinATier() {
        let ranked = HeroArtworkPlanner.rank([
            candidate("third", score: -2),
            candidate("first", score: 5),
            candidate("second", score: 1)
        ])
        XCTAssertEqual(ranked.map(\.reference), [ref("first"), ref("second"), ref("third")])
    }

    /// Equal candidates keep the order they arrived in. Swift's sort is not stable,
    /// and an unstable ranking here would let a rebuild swap two equally ranked
    /// backdrops and change a title's artwork for no reason at all.
    func testEqualCandidatesKeepTheirSuppliedOrder() {
        let names = (0..<12).map { "img\($0)" }
        let ranked = HeroArtworkPlanner.rank(names.map { candidate($0) })
        XCTAssertEqual(ranked.map(\.reference), names.map(ref))
    }

    // MARK: Source diversity

    /// Where a title has both server art and an online backdrop, the two screens are
    /// drawn from different sources rather than two crops of one shoot — even when a
    /// same-source picture ranks higher.
    func testDetailPrefersADifferentSourceThanHome() {
        let plan = HeroArtworkPlanner.selections(for: [
            candidate("server1", origin: .server, score: 10),
            candidate("server2", origin: .server, score: 9),
            candidate("tmdb", origin: .external, score: 1)
        ])
        XCTAssertEqual(chosen(plan, .homeHero), ref("server1"))
        XCTAssertEqual(chosen(plan, .detailBackdrop), ref("tmdb"))
    }

    /// Diversity is a preference, not a requirement — one source still yields two
    /// different pictures.
    func testASingleSourceStillYieldsTwoDifferentPictures() {
        let plan = HeroArtworkPlanner.selections(for: [
            candidate("server1", origin: .server, score: 10),
            candidate("server2", origin: .server, score: 9)
        ])
        XCTAssertEqual(chosen(plan, .homeHero), ref("server1"))
        XCTAssertEqual(chosen(plan, .detailBackdrop), ref("server2"))
    }

    // MARK: Ladders

    /// Each placement carries the whole pool, so a hero whose picture 404s falls to
    /// the next real image instead of collapsing to the text fallback.
    func testEachPlacementCarriesTheWholePoolAsAFallbackLadder() {
        let plan = HeroArtworkPlanner.selections(for: [
            candidate("a", score: 3),
            candidate("b", score: 2),
            candidate("c", score: 1)
        ])
        let home = plan.first { $0.placement == .homeHero }?.references
        let detail = plan.first { $0.placement == .detailBackdrop }?.references
        XCTAssertEqual(home, [ref("a"), ref("b"), ref("c")])
        XCTAssertEqual(detail, [ref("b"), ref("a"), ref("c")])
    }
}
