import XCTest
@testable import MetadataKit

final class LRCLIBLyricsProviderTests: XCTestCase {
    // MARK: - cleanedTitle word-boundary handling

    /// Regression for the missing `\b` word boundary: titles whose words merely
    /// end in "ft"/"feat" were truncated to a garbage prefix ("So", "Li", "Dri",
    /// "De", …), spawning a wasteful second LRCLIB query that could even match a
    /// different same-artist song.
    func testCleanedTitlePreservesWordsEndingInFtOrFeat() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Soft Rock"), "Soft Rock")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Lift Me Up"), "Lift Me Up")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Drift Away"), "Drift Away")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Defeat the Villain"), "Defeat the Villain")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Craft Beer Blues"), "Craft Beer Blues")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Theft of the Magi"), "Theft of the Magi")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Aftermath"), "Aftermath")
    }

    /// Legitimate featured-artist credits must still collapse to the core title.
    func testCleanedTitleStripsLegitimateFeatureCredits() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Lose Yourself (feat. Dido)"), "Lose Yourself")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Stan - feat. Dido"), "Stan")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Forever ft. Drake"), "Forever")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Crack a Bottle feat. Dr. Dre"), "Crack a Bottle")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("No Love [feat. Lil Wayne]"), "No Love")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Song ft Somebody"), "Song")
    }

    func testCleanedTitleStripsParentheticalsAndBrackets() {
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Tarzan Boy (Summer Version)"), "Tarzan Boy")
        XCTAssertEqual(LRCLIBLyricsProvider.cleanedTitle("Song [2010 Remaster]"), "Song")
    }

    // MARK: - HTTP negative-cache authority

    /// A definitive 404 is the only non-2xx status that may be trusted as a real
    /// "no lyrics" negative and cached.
    func testOnly404IsAuthoritativeNegative() {
        XCTAssertTrue(MetadataHTTP.nonSuccessIsAuthoritative(404))
    }

    /// Rate-limits, server/proxy errors, timeouts, and malformed-request codes
    /// must never be cached as a negative — they report as not authoritative so
    /// the resolver re-tries on a later play.
    func testTransientStatusesAreNotAuthoritative() {
        for code in [400, 401, 403, 408, 425, 429, 500, 502, 503, 520, 522] {
            XCTAssertFalse(
                MetadataHTTP.nonSuccessIsAuthoritative(code),
                "status \(code) must not be treated as an authoritative negative"
            )
        }
    }

    // MARK: - Artist-path duration version ceiling (M2)

    /// The artist-qualified "nearest held version" fallback must reject a synced
    /// record whose length is far from the track's — a different mix (radio edit
    /// vs 12"/extended) whose timestamps would drift the panel out of sync.
    func testVersionDurationCeilingRejectsWrongLengthVersions() {
        let track: TimeInterval = 240 // 4:00
        // Same recording, minor metadata/gapless slack — accept.
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 242, trackDuration: track))
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 234, trackDuration: track))
        // Exactly at the ceiling is still acceptable.
        XCTAssertTrue(LRCLIBLyricsProvider.versionDurationAcceptable(
            recordDuration: track + LRCLIBLyricsProvider.durationVersionCeiling, trackDuration: track))
        // Different cut (radio edit / extended mix) — reject so we show nothing
        // rather than drifting lyrics.
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 210, trackDuration: track))
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: 360, trackDuration: track))
        // A record with no duration of its own can't be matched safely.
        XCTAssertFalse(LRCLIBLyricsProvider.versionDurationAcceptable(recordDuration: nil, trackDuration: track))
    }
}
