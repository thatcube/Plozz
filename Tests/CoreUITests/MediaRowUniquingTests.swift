import XCTest
import CoreModels
@testable import CoreUI

/// Guards the row's `ForEach` precondition.
///
/// `ForEach` over `Identifiable` requires unique ids. Duplicates are undefined
/// behaviour and show up as a blank slot where a card should be — space is
/// reserved for the repeat and nothing is drawn in it. That is reachable in
/// normal use: two media shares can point at the same storage (one server over
/// NFS and over SMB), and identical relative paths then yield identical catalog
/// ids, which cross-server merging cannot fold until enrichment supplies the
/// external ids it matches on.
final class MediaRowUniquingTests: XCTestCase {
    private func item(_ id: String, _ title: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .movie)
    }

    func testCollapsesRepeatedIDs() {
        let deduped = MediaRowView.uniqued([
            item("movie:solo", "Solo"),
            item("movie:rogue-one", "Rogue One"),
            item("movie:solo", "Solo")
        ])
        XCTAssertEqual(deduped.map(\.id), ["movie:solo", "movie:rogue-one"])
    }

    /// The survivor must be the first occurrence: callers sort before handing the
    /// row its contents (Recently Added by date, Continue Watching by progress),
    /// so the copy the ordering chose is the one that has to remain.
    func testKeepsTheFirstOccurrenceAndOrder() {
        let deduped = MediaRowView.uniqued([
            item("a", "First"),
            item("b", "Second"),
            item("a", "Duplicate of first"),
            item("c", "Third")
        ])
        XCTAssertEqual(deduped.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(deduped.first?.title, "First")
    }

    func testLeavesAnAlreadyUniqueRowUntouched() {
        let items = [item("a", "A"), item("b", "B"), item("c", "C")]
        XCTAssertEqual(MediaRowView.uniqued(items).map(\.id), items.map(\.id))
    }

    func testHandlesAnEmptyRow() {
        XCTAssertTrue(MediaRowView.uniqued([]).isEmpty)
    }

    /// Different items that merely share a title are not duplicates — only the id
    /// identifies a row entry, and collapsing by title would hide real content.
    func testDoesNotCollapseDistinctIDsSharingATitle() {
        let deduped = MediaRowView.uniqued([
            item("share-a:avatar", "Avatar"),
            item("share-b:avatar", "Avatar")
        ])
        XCTAssertEqual(deduped.count, 2)
    }
}
