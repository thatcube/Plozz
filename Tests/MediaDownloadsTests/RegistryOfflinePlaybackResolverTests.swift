import CoreModels
import XCTest
@testable import MediaDownloads

final class RegistryOfflinePlaybackResolverTests: XCTestCase {

    private func makeResolver(root: URL) -> (DownloadedMediaRegistry, RegistryOfflinePlaybackResolver) {
        let registry = DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
        let storage = FixedDownloadStorageLocator(root: root)
        return (registry, RegistryOfflinePlaybackResolver(registry: registry, storage: storage))
    }

    func testReturnsLocalURLForCompletedDownloadWithFileOnDisk() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, resolver) = makeResolver(root: root)
        let storage = FixedDownloadStorageLocator(root: root)
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let record = try DownloadTestFactory.record(identity: identity, status: .completed)
        _ = try await registry.beginDownload(record)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)

        // Materialize the pinned file.
        let fileURL = try storage.pinnedFileURL(for: record)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("movie".utf8).write(to: fileURL)

        let item = DownloadTestFactory.movie(imdb: "tt1375666", title: "Inception")
        let resolved = await resolver.localPlaybackURL(for: item)
        XCTAssertEqual(resolved, fileURL)
    }

    func testReturnsNilWhenDownloadNotCompleted() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, resolver) = makeResolver(root: root)
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        _ = try await registry.beginDownload(
            try DownloadTestFactory.record(identity: identity, status: .downloading)
        )

        let item = DownloadTestFactory.movie(imdb: "tt1375666")
        let resolved = await resolver.localPlaybackURL(for: item)
        XCTAssertNil(resolved)
    }

    func testReturnsNilWhenFileMissingEvenIfMarkedCompleted() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (registry, resolver) = makeResolver(root: root)
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        let record = try DownloadTestFactory.record(identity: identity, status: .completed)
        _ = try await registry.beginDownload(record)
        try await registry.markCompleted(identityKey: record.identityKey, totalBytes: 100)
        // Deliberately DO NOT create the file on disk.

        let item = DownloadTestFactory.movie(imdb: "tt1375666")
        let resolved = await resolver.localPlaybackURL(for: item)
        XCTAssertNil(resolved)
    }

    func testReturnsNilForUnknownItem() async throws {
        let root = DownloadTestFactory.tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, resolver) = makeResolver(root: root)
        let item = DownloadTestFactory.movie(imdb: "tt9999999")
        let resolved = await resolver.localPlaybackURL(for: item)
        XCTAssertNil(resolved)
    }
}
