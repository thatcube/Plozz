import XCTest
@testable import CoreModels

final class TrickplayManifestTests: XCTestCase {
    private func makeManifest(
        thumbnailCount: Int = 250,
        intervalMs: Int = 10_000,
        cols: Int = 10,
        rows: Int = 10,
        tiles: Int = 3
    ) -> TrickplayManifest {
        TrickplayManifest(
            thumbnailWidth: 320,
            thumbnailHeight: 180,
            tileColumns: cols,
            tileRows: rows,
            thumbnailCount: thumbnailCount,
            intervalMs: intervalMs,
            tileResources: (0..<tiles).map {
                .publicURL(
                    try! SecretFreeURLSource(
                        url: URL(string: "https://h/Trickplay/320/\($0).jpg")!
                    )
                )
            }
        )
    }

    func testThumbnailIndexFloorsToInterval() {
        let m = makeManifest()
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 0), 0)
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 9.9), 0)
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 10), 1)
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 95), 9)
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 105), 10)
    }

    func testThumbnailIndexClampsToRange() {
        let m = makeManifest()
        XCTAssertEqual(m.thumbnailIndex(forSeconds: -5), 0)
        XCTAssertEqual(m.thumbnailIndex(forSeconds: 999_999), 249)
    }

    func testTileResolvesCorrectImageAndCrop() {
        let m = makeManifest()

        // First thumbnail: tile 0, top-left.
        let first = m.tile(forSeconds: 0)
        XCTAssertEqual(first?.resource.immediateURL?.lastPathComponent, "0.jpg")
        XCTAssertEqual(first?.cropX, 0)
        XCTAssertEqual(first?.cropY, 0)
        XCTAssertEqual(first?.cropWidth, 320)
        XCTAssertEqual(first?.cropHeight, 180)

        // idx 9 -> last column of first row.
        let ninth = m.tile(forSeconds: 95)
        XCTAssertEqual(ninth?.resource.immediateURL?.lastPathComponent, "0.jpg")
        XCTAssertEqual(ninth?.cropX, 2880)
        XCTAssertEqual(ninth?.cropY, 0)

        // idx 10 -> wraps to second row of first tile.
        let tenth = m.tile(forSeconds: 105)
        XCTAssertEqual(tenth?.cropX, 0)
        XCTAssertEqual(tenth?.cropY, 180)

        // idx 100 -> first thumbnail of the second tile.
        let secondTile = m.tile(forSeconds: 1005)
        XCTAssertEqual(
            secondTile?.resource.immediateURL?.lastPathComponent,
            "1.jpg"
        )
        XCTAssertEqual(secondTile?.cropX, 0)
        XCTAssertEqual(secondTile?.cropY, 0)

        // idx 249 -> last thumbnail in the third tile (col 9, row 4).
        let last = m.tile(forSeconds: 2495)
        XCTAssertEqual(last?.resource.immediateURL?.lastPathComponent, "2.jpg")
        XCTAssertEqual(last?.cropX, 2880)
        XCTAssertEqual(last?.cropY, 720)
    }

    func testUnusableManifestsReturnNoTile() {
        XCTAssertNil(makeManifest(thumbnailCount: 0).tile(forSeconds: 0))
        XCTAssertNil(makeManifest(intervalMs: 0).tile(forSeconds: 0))
        XCTAssertNil(makeManifest(tiles: 0).tile(forSeconds: 0))
    }
}
