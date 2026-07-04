import XCTest
@testable import CoreModels

/// Exercises the provider-agnostic alphabet fast-scroll offset math shared by
/// Jellyfin (`NameLessThan` cumulative offsets) and Plex (`firstCharacter`
/// per-letter counts). All the tricky ascending-vs-descending index arithmetic
/// lives here so it is verified without a network.
final class LibraryLetterIndexTests: XCTestCase {

    // MARK: bucket(forPrefix:)

    func testBucketMapsLettersCaseInsensitively() {
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "apple"), "A")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "Zoo"), "Z")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "m"), "M")
    }

    func testBucketFoldsDigitsSymbolsAndNonLatinIntoHash() {
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "3 Days"), "#")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "$$$"), "#")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: ""), "#")
        // A non-Latin first character has no A–Z rail bucket, so it folds to "#".
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "économie"), "#")
    }

    func testRailLettersAreHashThenAToZ() {
        XCTAssertEqual(LibraryLetterIndex.railLetters.first, "#")
        XCTAssertEqual(LibraryLetterIndex.railLetters.count, 27)
        XCTAssertEqual(LibraryLetterIndex.railLetters.last, "Z")
        XCTAssertEqual(LibraryLetterIndex.railLetters[1], "A")
    }

    // MARK: entries(bucketCountsAscending:direction:)

    func testAscendingBucketsProduceCumulativeOffsetsAndDropEmpties() {
        let buckets: [(letter: String, count: Int)] =
            [("#", 2), ("A", 3), ("B", 0), ("C", 5)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .ascending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "#", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 2),
            LibraryLetterIndexEntry(letter: "C", startIndex: 5)
        ])
    }

    func testDescendingBucketsMirrorOffsets() {
        let buckets: [(letter: String, count: Int)] =
            [("#", 2), ("A", 3), ("B", 0), ("C", 5)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .descending
        )
        // Descending name sort shows C…A…# top-to-bottom; each letter's first
        // item is at total - (itemsUpToAndIncludingIt).
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "C", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 5),
            LibraryLetterIndexEntry(letter: "#", startIndex: 8)
        ])
    }

    func testAllEmptyBucketsProduceNoEntries() {
        let buckets: [(letter: String, count: Int)] = [("#", 0), ("A", 0)]
        XCTAssertTrue(
            LibraryLetterIndex.entries(bucketCountsAscending: buckets, direction: .ascending).isEmpty
        )
    }

    func testNegativeCountsAreClampedToEmpty() {
        let buckets: [(letter: String, count: Int)] = [("A", -5), ("B", 4)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .ascending
        )
        XCTAssertEqual(entries, [LibraryLetterIndexEntry(letter: "B", startIndex: 0)])
    }

    // MARK: entries(lessThanOffsetsByLetter:totalCount:direction:)

    /// `NameLessThan` offsets that describe the same library as the bucket tests
    /// above: 2 items before "A" (the "#" bucket), 3 A's, 0 B's, 5 C's = 10 total.
    private func sampleLessThanOffsets() -> [String: Int] {
        var offsets: [String: Int] = [:]
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            offsets[String(UnicodeScalar(scalar)!)] = 10
        }
        offsets["A"] = 2   // 2 items sort before "A" → "#" bucket size 2
        offsets["B"] = 5   // 3 items in "A"
        offsets["C"] = 5   // 0 items in "B"
        return offsets     // 5 items in "C" (10 - 5), rest empty
    }

    func testLessThanOffsetsAscendingMatchBucketMath() {
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: sampleLessThanOffsets(),
            totalCount: 10, direction: .ascending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "#", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 2),
            LibraryLetterIndexEntry(letter: "C", startIndex: 5)
        ])
    }

    func testLessThanOffsetsDescendingMatchBucketMath() {
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: sampleLessThanOffsets(),
            totalCount: 10, direction: .descending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "C", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 5),
            LibraryLetterIndexEntry(letter: "#", startIndex: 8)
        ])
    }

    func testZeroTotalProducesNoEntries() {
        XCTAssertTrue(
            LibraryLetterIndex.entries(
                lessThanOffsetsByLetter: [:], totalCount: 0, direction: .ascending
            ).isEmpty
        )
    }

    func testAllItemsAfterZFallIntoZBucket() {
        // Every item sorts >= "Z" (nothing before any letter): all land in "Z".
        var offsets: [String: Int] = [:]
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            offsets[String(UnicodeScalar(scalar)!)] = 0
        }
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: offsets, totalCount: 4, direction: .ascending
        )
        XCTAssertEqual(entries, [LibraryLetterIndexEntry(letter: "Z", startIndex: 0)])
    }
}
