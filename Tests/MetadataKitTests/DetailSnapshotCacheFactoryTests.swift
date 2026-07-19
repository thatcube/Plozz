import XCTest
import CoreModels
@testable import MetadataKit

/// Verifies the E1 factory contract: one memoized cache instance per scope digest,
/// distinct instances (and on-disk directories) per identity, and no re-construction
/// on repeated requests for an equal scope.
@MainActor
final class DetailSnapshotCacheFactoryTests: XCTestCase {
    private final class CallBox {
        var calls: [(URL?, String)] = []
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("factory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSameScopeReturnsSameInstance() {
        let factory = DetailSnapshotCacheFactory(baseDirectory: nil) { base, scope in
            DetailSnapshotCache(directory: base, scope: scope, directoryContents: { _, _ in [] })
        }
        let scope = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1")
        let first = factory.cache(for: scope)
        let second = factory.cache(for: scope)
        XCTAssertTrue(first === second)
    }

    func testDifferentScopesReturnDifferentInstances() {
        let factory = DetailSnapshotCacheFactory(baseDirectory: nil) { base, scope in
            DetailSnapshotCache(directory: base, scope: scope, directoryContents: { _, _ in [] })
        }
        let a = factory.cache(for: DetailSnapshotCacheScope(profileID: "a", identityMaterial: "x"))
        let b = factory.cache(for: DetailSnapshotCacheScope(profileID: "b", identityMaterial: "x"))
        XCTAssertFalse(a === b)
    }

    func testRepeatedEqualScopeConstructsCacheOnce() {
        let box = CallBox()
        let factory = DetailSnapshotCacheFactory(baseDirectory: nil) { base, scope in
            box.calls.append((base, scope))
            return DetailSnapshotCache(directory: base, scope: scope, directoryContents: { _, _ in [] })
        }
        let scope = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1")
        _ = factory.cache(for: scope)
        _ = factory.cache(for: scope)
        _ = factory.cache(for: scope)
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls.first?.1, scope.directoryComponent)
    }

    func testScopedCacheWritesUnderItsDigestDirectory() async {
        let base = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let factory = DetailSnapshotCacheFactory(baseDirectory: base)
        let scope = DetailSnapshotCacheScope(profileID: "p", identityMaterial: "a#r1")
        let cache = factory.cache(for: scope)
        await cache.store(
            DetailSnapshotCache.Snapshot(
                item: MediaItem(id: "m1", title: "Movie", kind: .movie),
                children: []
            ),
            for: "k1"
        )
        await cache.awaitPendingPrune()

        let scoped = base
            .appendingPathComponent("plozz-detail-cache-v5")
            .appendingPathComponent(scope.directoryComponent)
        let unscopedDefault = base
            .appendingPathComponent("plozz-detail-cache-v5")
            .appendingPathComponent("default")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scoped.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unscopedDefault.path))
    }
}
