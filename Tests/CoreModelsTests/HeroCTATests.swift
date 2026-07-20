import XCTest
import CoreModels

/// The pure hero CTA decision that drives Play vs. Request vs. download status vs.
/// no-button for featured (Seerr) titles, and Play/Resume for ordinary library
/// items. Kept exhaustive so the UI's button choice can never drift.
final class HeroCTATests: XCTestCase {
    private func item(_ availability: MediaAvailabilityStatus?, download: Double? = nil) -> MediaItem {
        MediaItem(id: "x", title: "T", kind: .movie, availability: availability, downloadProgress: download)
    }

    func testOrdinaryLibraryItemIsAlwaysPlay() {
        XCTAssertEqual(item(nil).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(nil).heroCTA(seerConnected: true), .play)
    }

    func testOwnedFeaturedIsPlayRegardlessOfConnection() {
        XCTAssertEqual(item(.available).heroCTA(seerConnected: false), .play)
        XCTAssertEqual(item(.available).heroCTA(seerConnected: true), .play)
        XCTAssertEqual(item(.partiallyAvailable).heroCTA(seerConnected: true), .play)
    }

    func testRequestableOnlyWhenConnected() {
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: true), .request)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: true), .request)
        // Not connected → no Play/Request button (still shown in the carousel).
        XCTAssertEqual(item(.unknown).heroCTA(seerConnected: false), .unavailable)
        XCTAssertEqual(item(.deleted).heroCTA(seerConnected: false), .unavailable)
    }

    func testPendingShowsRequestedOnlyWhenConnected() {
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: true), .requested)
        XCTAssertEqual(item(.pending).heroCTA(seerConnected: false), .unavailable)
    }

    func testProcessingShowsDownloadingOnlyWithActiveProgress() {
        // Actively downloading (a real queue item reports progress) → Downloading %.
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: true), .downloading(progress: 0.42))
        // Approved but not downloading yet (no queue item / size) → still Requested,
        // NOT "Downloading".
        XCTAssertEqual(item(.processing, download: nil).heroCTA(seerConnected: true), .requested)
        XCTAssertEqual(item(.processing, download: 0.42).heroCTA(seerConnected: false), .unavailable)
    }

    // MARK: - isNotInLibraryDiscovery

    func testNotInLibraryDiscoveryIsFalseForLibraryAndOwnedTitles() {
        // Ordinary library item (no availability) and owned featured titles must
        // NOT be treated as discovery — they resolve to a real library copy, so
        // their Play/Watchlist/etc. actions stay live.
        XCTAssertFalse(item(nil).isNotInLibraryDiscovery)
        XCTAssertFalse(item(.available).isNotInLibraryDiscovery)
        XCTAssertFalse(item(.partiallyAvailable).isNotInLibraryDiscovery)
    }

    func testNotInLibraryDiscoveryIsTrueForRequestableAndInFlightTitles() {
        XCTAssertTrue(item(.unknown).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.pending).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.processing).isNotInLibraryDiscovery)
        XCTAssertTrue(item(.deleted).isNotInLibraryDiscovery)
    }

    func testPlexDiscoverWatchlistStubHasNoPlayableLibraryTarget() {
        let discover = MediaItem(
            id: "5d7768342ec6b5001f6bbacd",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"]
        )

        XCTAssertFalse(discover.hasPlayableLibraryTarget())
    }

    func testPlexDiscoverWatchlistStubBecomesPlayableWithLibrarySource() {
        let discover = MediaItem(
            id: "5d7768342ec6b5001f6bbacd",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"]
        )
        let librarySource = MediaSourceRef(
            accountID: "plex-account",
            itemID: "48291",
            providerKind: .plex
        )

        XCTAssertTrue(discover.hasPlayableLibraryTarget(additionalSources: [librarySource]))
    }

    func testOrdinaryAndOwnedPlexItemsHavePlayableLibraryTargets() {
        XCTAssertTrue(item(nil).hasPlayableLibraryTarget())

        let owned = MediaItem(
            id: "48291",
            title: "13 Going on 30",
            kind: .movie,
            providerIDs: ["PlexGuid": "plex://movie/5d7768342ec6b5001f6bbacd"]
        )
        XCTAssertTrue(owned.hasPlayableLibraryTarget())
    }

    func testSeasonRequestAvailabilityKeepsOnlyMissingAndInFlightSeasons() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .available),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .unknown),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .pending),
                MediaSeasonRequestState(number: 4, title: "Season 4", status: .processing),
                MediaSeasonRequestState(number: 5, title: "Season 5", status: .partiallyAvailable),
                MediaSeasonRequestState(number: 6, title: "Season 6", status: .pending, requestFailed: true)
            ]
        )

        XCTAssertEqual(availability.requestableSeasonNumbers, [2])
        XCTAssertEqual(availability.requestPickerSeasons.map(\.number), [2, 3, 4, 6])
        XCTAssertTrue(availability.hasSeasonRequestContent)
    }

    func testMarkingSeasonsRequestedOnlyChangesRequestableSelections() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .available),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .unknown),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .pending)
            ]
        )

        let updated = availability.markingRequested([1, 2, 3])

        XCTAssertEqual(updated.seasons.map(\.status), [.available, .pending, .pending])
    }

    func testMarkingOwnedSeasonsAvailableRemovesThemFromRequestPicker() {
        let availability = MediaRequestAvailability(
            status: .partiallyAvailable,
            seasons: [
                MediaSeasonRequestState(number: 1, title: "Season 1", status: .unknown),
                MediaSeasonRequestState(number: 2, title: "Season 2", status: .pending),
                MediaSeasonRequestState(number: 3, title: "Season 3", status: .unknown)
            ]
        )

        let updated = availability.markingAvailable([1, 2])

        XCTAssertEqual(updated.seasons.map(\.status), [.available, .available, .unknown])
        XCTAssertEqual(updated.requestPickerSeasons.map(\.number), [3])
    }
}
