import XCTest
@testable import ProviderShare

/// A directory recorded by an interrupted scan must not be mistaken for a
/// finished, empty leaf and skipped forever.
///
/// The regression: 165 of 273 show folders on the maintainer's share were
/// invisible in the share's TV Shows library. Every one of them kept its
/// episodes in `Season N` subfolders; shows with episodes flat in the show
/// folder were fine. `dir_state` held the show folder (so a listing had once
/// succeeded) while `assets` held nothing under it, and because a folder's own
/// mtime never moves when a grandchild changes, the incremental skip re-skipped
/// it on every later pass. It could never recover on its own.
final class ShareScannerLeafEvidenceTests: XCTestCase {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plozz-leaf-evidence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func episode(_ path: String, series: String, season: Int, number: Int) -> CatalogAsset {
        CatalogAsset(
            relPath: path,
            basename: (path as NSString).lastPathComponent,
            size: 1_000,
            modifiedAt: Date(),
            kind: .episode,
            library: .tv,
            title: "Episode \(number)",
            year: nil,
            seriesTitle: series,
            seriesKey: ShareCatalogID.seriesKey(fromTitle: series),
            season: season,
            episode: number
        )
    }

    func testOnlyDirectoriesHoldingIndexedFilesCountAsFinishedLeaves() async {
        let store = ShareCatalogStore(accountKey: "leaf", directory: tempDir())
        // "Bridgerton" keeps its episodes directly in the show folder, so the
        // folder itself holds indexed files. "Cobra Kai" keeps them a level down
        // in "Season 1".
        await store.upsert([
            episode("TV Shows/Bridgerton/Bridgerton.S01E01.mkv",
                    series: "Bridgerton", season: 1, number: 1),
            episode("TV Shows/Cobra Kai/Season 1/Cobra Kai S01E01.mkv",
                    series: "Cobra Kai", season: 1, number: 1),
        ], scanID: 1)

        let withFiles = await store.directoriesWithRecordedFiles()

        XCTAssertTrue(
            withFiles.contains("TV Shows/Bridgerton"),
            "a folder whose own files are indexed is a finished leaf"
        )
        XCTAssertTrue(
            withFiles.contains("TV Shows/Cobra Kai/Season 1"),
            "the season folder is where Cobra Kai's files actually live"
        )
        XCTAssertFalse(
            withFiles.contains("TV Shows/Cobra Kai"),
            "the show folder holds no files of its own, so it is not a finished leaf"
        )
        XCTAssertFalse(withFiles.contains("TV Shows"))
    }

    func testAnEmptyCatalogClaimsNoFinishedLeaves() async {
        let store = ShareCatalogStore(accountKey: "empty", directory: tempDir())
        let withFiles = await store.directoriesWithRecordedFiles()
        XCTAssertTrue(
            withFiles.isEmpty,
            "nothing is indexed, so nothing may be skipped as already-scanned"
        )
    }

    func testTopLevelFilesReportTheRootAsHoldingFiles() async {
        let store = ShareCatalogStore(accountKey: "root", directory: tempDir())
        await store.upsert([
            CatalogAsset(
                relPath: "Loose.Movie.2019.mkv", basename: "Loose.Movie.2019.mkv",
                size: 10, modifiedAt: Date(), kind: .movie, library: .movies,
                title: "Loose Movie", year: 2019,
                seriesTitle: nil, seriesKey: nil, season: nil, episode: nil
            )
        ], scanID: 1)

        let withFiles = await store.directoriesWithRecordedFiles()
        XCTAssertTrue(
            withFiles.contains(""),
            "a file at the share root makes the root itself a folder we have content for"
        )
    }
}
