import XCTest
import CoreModels
@testable import MetadataKit

/// Guards the candidate-selection rules for Wikipedia biographies.
///
/// This is the part that decides whether a viewer sees the right person's life
/// story, the wrong one's, or none. Every case below is a real search result
/// captured from the live API while building the feature — the ranking, titles
/// and descriptions are verbatim, because the failure mode being defended
/// against is subtle and entirely data-shaped.
final class WikipediaPersonBiographyProviderTests: XCTestCase {
    private typealias Page = WikipediaPersonBiographyProvider.SearchResponse.Page

    private func page(_ title: String, _ description: String?) -> Page {
        Page(title: title, extract: "…", description: description, index: nil)
    }

    private func accepts(_ page: Page, as name: String) -> Bool {
        WikipediaPersonBiographyProvider.isPlausiblePerson(page: page, name: name)
    }

    // MARK: Picking the right namesake

    /// "Richard Armitage" returns the actor, a US Deputy Secretary of State and a
    /// disambiguation page. Only the actor may be shown under an actor's headshot.
    func testPrefersTheScreenNamesakeOverAnUnrelatedOne() {
        XCTAssertTrue(accepts(
            page("Richard Armitage (actor)", "British actor (born 1971)"),
            as: "Richard Armitage"
        ))
        XCTAssertFalse(accepts(
            page("Richard Armitage (government official)", "American diplomat and government official (1945–2025)"),
            as: "Richard Armitage"
        ))
    }

    /// Wikidata describes disambiguation pages this way rather than using the
    /// word "disambiguation", so matching that word alone would let them through.
    func testRejectsDisambiguationPages() {
        XCTAssertFalse(accepts(
            page("Martin Freeman (disambiguation)", "Topics referred to by the same term"),
            as: "Martin Freeman"
        ))
        XCTAssertFalse(accepts(
            page("Richard Armitage", "Disambiguation page"),
            as: "Richard Armitage"
        ))
    }

    /// A different person who shares a surname *and* passes the occupation check
    /// on his own merits — rejected only because the given name is absent.
    func testRejectsADifferentPersonSharingASurname() {
        XCTAssertFalse(accepts(
            page("Joe Freeman", "English actor (born 2006)"),
            as: "Martin Freeman"
        ))
    }

    /// A longer name that merely *contains* the requested one is a different
    /// person. "Michael B. Jordan" holds both tokens of "Michael Jordan" and is
    /// genuinely an actor, so the occupation check clears him on his own merits —
    /// only comparing the token sets both ways separates them.
    func testRejectsALongerNameContainingTheRequestedOne() {
        XCTAssertFalse(accepts(
            page("Michael B. Jordan", "American actor (born 1987)"),
            as: "Michael Jordan"
        ))
    }

    /// Wikipedia's parenthetical qualifier is not an extra name token.
    func testAcceptsAParentheticalQualifier() {
        XCTAssertTrue(accepts(
            page("Richard Armitage (actor)", "British actor (born 1971)"),
            as: "Richard Armitage"
        ))
    }

    /// A server may hold a name in the opposite order to Wikipedia: "Kayano Ai"
    /// against "Ai Kayano". Substring matching rejects every Japanese voice
    /// actor on that basis, which is why the title check is token-wise.
    func testAcceptsAReorderedName() {
        XCTAssertTrue(accepts(
            page("Ai Kayano", "Japanese voice actress (born 1987)"),
            as: "Kayano Ai"
        ))
    }

    /// Titles rank highly for their cast's names and are described as
    /// "television series", which matches the occupation list — so it is the
    /// name check that has to exclude them.
    func testRejectsTitlesThatRankForAPersonName() {
        XCTAssertFalse(accepts(
            page("Fool Me Once (TV series)", "British television series"),
            as: "Richard Armitage"
        ))
        XCTAssertFalse(accepts(
            page("Black Panther: Wakanda Forever", "2022 Marvel Studios film"),
            as: "Chadwick Boseman"
        ))
    }

    /// Someone real, correctly named, but with no screen occupation.
    func testRejectsAPersonWithNoScreenOccupation() {
        XCTAssertFalse(accepts(
            page("Jane Smith", "British chemist"),
            as: "Jane Smith"
        ))
    }

    /// Wikipedia omits the short description for some articles; without it there
    /// is nothing to verify the person against, and a guess is worse than none.
    func testRejectsWhenThereIsNoDescriptionToVerifyAgainst() {
        XCTAssertFalse(accepts(page("Martin Freeman", nil), as: "Martin Freeman"))
        XCTAssertFalse(accepts(page("Martin Freeman", ""), as: "Martin Freeman"))
    }

    func testAcceptsAccentedAndPunctuatedNames() {
        XCTAssertTrue(accepts(
            page("Penélope Cruz", "Spanish actress (born 1974)"),
            as: "Penelope Cruz"
        ))
        XCTAssertTrue(accepts(
            page("Ai Kayano", "Japanese voice actress"),
            as: "Kayano, Ai"
        ))
    }

    // MARK: Trimming

    func testKeepsShortBiographiesWhole() {
        let text = "An English actor."
        XCTAssertEqual(WikipediaPersonBiographyProvider.trimmed(text, to: 100), text)
    }

    /// Clips at a sentence boundary so the text never stops mid-word.
    func testClipsLongBiographiesAtASentenceBoundary() {
        let text = "One sentence here. Two sentence here. Three sentence here."
        let result = WikipediaPersonBiographyProvider.trimmed(text, to: 40)
        XCTAssertEqual(result, "One sentence here. Two sentence here.")
        XCTAssertFalse(result.hasSuffix("…"))
    }

    /// When the only sentence break sits very early, clipping there would throw
    /// away most of the allowance — so it falls back to an ellipsis instead.
    func testFallsBackToAnEllipsisWhenTheFirstSentenceEndsTooEarly() {
        let text = "Hi. " + String(repeating: "a", count: 200)
        let result = WikipediaPersonBiographyProvider.trimmed(text, to: 100)
        XCTAssertTrue(result.hasSuffix("…"))
        XCTAssertGreaterThan(result.count, 50)
    }
}
