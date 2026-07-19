#if canImport(UIKit)
import CoreModels
@testable import CoreUI
import UIKit
import XCTest

/// Locks the Step 6 additions to ``LocalArtworkDerivedCache``: current-byte-size
/// accounting, a user-adjustable cap that trims immediately, and clear-all.
final class LocalArtworkDerivedCacheByteSizeTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-bytesize-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func image(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
    }

    private func store(_ cache: LocalArtworkDerivedCache, key: String, color: UIColor) async {
        await cache.store(
            Self.image(color),
            key: key,
            accountID: "acct",
            credentialRevision: "rev",
            sourceFingerprint: "fp-\(key)",
            variant: .posterCard
        )
    }

    func testCurrentByteSizeTracksStoredBytes() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LocalArtworkDerivedCache(
            directory: directory, byteCap: 10_000_000, warningByteCap: 8_000_000,
            maximumAge: 30 * 24 * 60 * 60, now: Date.init
        )
        let empty = await cache.currentByteSize()
        XCTAssertEqual(empty, 0)
        await store(cache, key: "a", color: .red)
        let one = await cache.currentByteSize()
        let usage = await cache.usageBytes()
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(one, usage)
        await store(cache, key: "b", color: .green)
        let two = await cache.currentByteSize()
        XCTAssertGreaterThan(two, one)
    }

    func testSetByteCapTrimsImmediately() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LocalArtworkDerivedCache(
            directory: directory, byteCap: 10_000_000, warningByteCap: 8_000_000,
            maximumAge: 30 * 24 * 60 * 60, now: Date.init
        )
        for i in 0..<6 { await store(cache, key: "k\(i)", color: .blue) }
        let before = await cache.currentByteSize()
        XCTAssertGreaterThan(before, 0)

        await cache.setByteCap(before / 2)
        let after = await cache.currentByteSize()
        XCTAssertLessThanOrEqual(after, before / 2)
    }

    func testClearRemovesEverything() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LocalArtworkDerivedCache(
            directory: directory, byteCap: 10_000_000, warningByteCap: 8_000_000,
            maximumAge: 30 * 24 * 60 * 60, now: Date.init
        )
        await store(cache, key: "a", color: .red)
        await store(cache, key: "b", color: .green)
        let before = await cache.currentByteSize()
        XCTAssertGreaterThan(before, 0)
        await cache.clear()
        let after = await cache.currentByteSize()
        XCTAssertEqual(after, 0)
        let hit = await cache.data(for: "a", accountID: "acct", credentialRevision: "rev", sourceFingerprint: "fp-a")
        XCTAssertNil(hit)
    }
}
#endif
