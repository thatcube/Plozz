import XCTest
import CoreModels
@testable import FeatureMusic

final class MusicFormatTests: XCTestCase {
    func testDurationUnderAnHour() {
        XCTAssertEqual(MusicFormat.duration(187), "3:07")
        XCTAssertEqual(MusicFormat.duration(0), "0:00")
        XCTAssertEqual(MusicFormat.duration(59), "0:59")
    }

    func testDurationOverAnHour() {
        XCTAssertEqual(MusicFormat.duration(3753), "1:02:33")
    }

    func testDurationHandlesNilAndInvalid() {
        XCTAssertEqual(MusicFormat.duration(nil), "--:--")
        XCTAssertEqual(MusicFormat.duration(-5), "--:--")
        XCTAssertEqual(MusicFormat.duration(.infinity), "--:--")
    }
}

final class MusicPagePagingTests: XCTestCase {
    func testCountAndHasMore() {
        let page = MusicPage(
            albums: [MusicAlbum(id: "a", title: "A"), MusicAlbum(id: "b", title: "B")],
            startIndex: 0,
            totalCount: 10
        )
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.endIndex, 2)
        XCTAssertTrue(page.hasMore)
    }

    func testNoMoreWhenExhausted() {
        let page = MusicPage(
            tracks: [MusicTrack(id: "t", title: "T")],
            startIndex: 9,
            totalCount: 10
        )
        XCTAssertFalse(page.hasMore)
    }
}

final class MusicTrackSubtitleTests: XCTestCase {
    func testSubtitleCombinesArtistAndAlbum() {
        let track = MusicTrack(id: "t", title: "Song", albumTitle: "LP", artistName: "Artist")
        XCTAssertEqual(track.subtitle, "Artist · LP")
    }

    func testSubtitleFallsBackToWhateverIsPresent() {
        XCTAssertEqual(MusicTrack(id: "t", title: "S", artistName: "Only Artist").subtitle, "Only Artist")
        XCTAssertNil(MusicTrack(id: "t", title: "S").subtitle)
    }
}

/// Authority matrix for caching a *negative* (no synced lyrics) resolve. These
/// guard the v2→v5 cache-poisoning regression history — particularly H1a, where
/// a background prefetch (title-only fallback disabled) that finds nothing for a
/// track filed under a different artist must NOT cache an authoritative negative,
/// or it suppresses the visible play's full fallback for 7 days.
final class LyricsNegativeAuthorityTests: XCTestCase {
    /// Baseline: every needed source answered with full effort → authoritative.
    func testFullEffortReachableNegativeIsAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// H1a: a prefetch that skipped the title-only fallback while a duration was
    /// available is reduced-effort — the fallback that finds different-artist
    /// filings never ran — so its negative is NOT authoritative.
    func testPrefetchWithoutTitleOnlyFallbackIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: true
        ))
    }

    /// Without a usable duration the visible resolve couldn't run the title-only
    /// fallback either (it's duration-gated), so a fallback-disabled negative is
    /// as complete as it'll get and stays authoritative.
    func testFallbackDisabledButNoDurationStaysAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: false
        ))
    }

    /// An unreachable server (offline/DNS/TLS) can never produce a trusted
    /// negative regardless of the other signals.
    func testUnreachableServerIsNeverAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: false,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB skipped purely for a missing artist → incomplete → not authoritative.
    func testMissingArtistSkipIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: true,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB available but unreachable (throttled/cancelled mid-skip) → the song
    /// it might have had goes unconfirmed → not authoritative.
    func testAvailableButUnreachableLRCLIBIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// B / H1b: lyrics were turned OFF, so LRCLIB was skipped and only the server
    /// was consulted. That skip is a temporary user setting, not a verdict — the
    /// server-only negative must NOT be cached as authoritative, or enabling
    /// lyrics and replaying would keep reading the poisoned negative for 7 days.
    func testLyricsDisabledServerOnlyNegativeIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// The disabled-skip guard holds even with no usable duration: re-enabling
    /// lyrics should still trigger a fresh LRCLIB lookup, so the negative formed
    /// while disabled is never authoritative.
    func testLyricsDisabledStaysNonAuthoritativeWithoutDuration() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: false
        ))
    }
}
