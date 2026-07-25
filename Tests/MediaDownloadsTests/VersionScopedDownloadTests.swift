import CoreModels
import XCTest
@testable import MediaDownloads

/// A title can exist as several files (4K, 1080p, a remux). Downloads used to be
/// keyed by title identity alone, which had two consequences:
///
///  * only one version of a title could be downloaded — a second overwrote the
///    first's record;
///  * playback matched on the title, so whichever copy happened to be on disk
///    was played for EVERY version the user picked. Nothing errored; you just
///    silently got the wrong file.
///
/// These tests pin the version-scoped behaviour that fixes both.
final class VersionScopedDownloadTests: XCTestCase {
    private func makeRegistry() -> DownloadedMediaRegistry {
        DownloadedMediaRegistry(store: InMemoryDownloadedMediaStore())
    }

    private func movieSelecting(_ versionID: String?) -> MediaItem {
        var item = DownloadTestFactory.movie(imdb: "tt1375666", title: "Inception")
        item.selectedVersionID = versionID
        return item
    }

    func testTwoVersionsOfOneTitleCoexist() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(uhd)
        _ = try await registry.beginDownload(hd)

        XCTAssertNotEqual(
            uhd.identityKey,
            hd.identityKey,
            "each version needs its own key, or one download overwrites the other"
        )
        let all = await registry.all()
        XCTAssertEqual(all.count, 2)
    }

    func testLookupReturnsTheSelectedVersionNotJustAnyDownloadedCopy() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(uhd)
        _ = try await registry.beginDownload(hd)

        let found = await registry.record(
            for: movieSelecting("v-1080"), versionID: "v-1080"
        )
        XCTAssertEqual(found?.identityKey, hd.identityKey)
    }

    /// The regression itself: selecting a version that ISN'T downloaded must
    /// report nothing, so playback streams it instead of substituting the
    /// downloaded one.
    func testUndownloadedVersionReportsNoLocalCopy() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let hd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-1080", status: .completed
        )
        _ = try await registry.beginDownload(hd)

        let found = await registry.record(
            for: movieSelecting("v-4k"), versionID: "v-4k"
        )
        XCTAssertNil(
            found,
            "4K isn't downloaded, so it must stream — not silently play the 1080p file"
        )
    }

    /// "Is this title available offline at all?" must still see version-scoped
    /// copies, otherwise download badges and the offline library go blank.
    func testAnyVersionLookupStillFindsAVersionScopedDownload() async throws {
        let registry = makeRegistry()
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")

        let uhd = try DownloadTestFactory.record(
            identity: identity, versionID: "v-4k", status: .completed
        )
        _ = try await registry.beginDownload(uhd)

        let found = await registry.record(for: movieSelecting(nil))
        XCTAssertEqual(found?.identityKey, uhd.identityKey)
    }

    /// Records with no version concept keep their historic un-suffixed key.
    func testVersionlessRecordsKeepTheirOriginalKey() {
        let identity = DownloadTestFactory.imdbIdentity("tt1375666")
        XCTAssertEqual(
            MediaIdentityKey.string(for: identity, versionID: nil),
            MediaIdentityKey.string(for: identity)
        )
        XCTAssertEqual(
            MediaIdentityKey.string(for: identity, versionID: ""),
            MediaIdentityKey.string(for: identity)
        )
    }
}
