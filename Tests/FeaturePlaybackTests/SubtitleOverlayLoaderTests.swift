#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// Records the model side effects `SubtitleOverlayLoader` triggers and exposes
/// the selection facts it re-checks, so the loader's fetch/parse/apply/guard
/// behaviour can be driven with canned sidecar bytes and no real view model.
@MainActor
private final class SpyOverlayHost: SubtitleOverlayLoaderHost {
    var primarySubtitleSelectionID: Int?
    var secondarySubtitleSelectionID: Int?
    var resolvedURL: URL? = URL(string: "https://example.test/sub.vtt")

    private(set) var appliedPrimary: [SubtitleCueStream?] = []
    private(set) var appliedSecondary: [SubtitleCueStream?] = []
    private(set) var detected: [Int: String] = [:]
    private(set) var reloadCount = 0
    private(set) var secondaryStatuses: [SecondarySubtitleStatus] = []

    func overlayResolveDeliveryURL(_ track: MediaTrack) async throws -> URL? { resolvedURL }
    func overlayApplyPrimaryCues(_ stream: SubtitleCueStream?) { appliedPrimary.append(stream) }
    func overlayApplySecondaryCues(_ stream: SubtitleCueStream?) { appliedSecondary.append(stream) }
    func overlayDetectedLanguage(for id: Int) -> String? { detected[id] }
    func overlayRecordDetectedLanguage(_ language: String, for id: Int) { detected[id] = language }
    func overlayReloadTrackOptions() { reloadCount += 1 }
    func overlaySetSecondaryStatus(_ status: SecondarySubtitleStatus) { secondaryStatuses.append(status) }
    #if DEBUG
    func overlaySetPrimaryDiagnostic(route: String, cues: Int?) {}
    #endif
}

final class SubtitleOverlayLoaderTests: XCTestCase {

    private static let vtt = """
    WEBVTT

    00:00:01.000 --> 00:00:04.000
    Hello there, this is a subtitle line with plenty of English words.

    00:00:05.000 --> 00:00:08.000
    And a second cue to make the sample long enough to classify.
    """

    private func sidecarTrack(_ id: Int, language: String? = nil) -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "Sub \(id)", language: language,
            deliverySource: .localFile(URL(fileURLWithPath: "/tmp/\(id).vtt"))
        )
    }

    private func embeddedTrack(_ id: Int) -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: "Embedded \(id)")
    }

    /// Poll the main actor until `cond` holds or we time out.
    @MainActor
    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor
    private func makeLoader(host: SpyOverlayHost, data: Data) -> SubtitleOverlayLoader {
        SubtitleOverlayLoader(host: host, fetch: { _ in data })
    }

    // MARK: - Primary

    @MainActor
    func testLoadPrimaryAppliesParsedCuesForCurrentSelection() async {
        let host = SpyOverlayHost()
        host.primarySubtitleSelectionID = 1
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadPrimary(sidecarTrack(1))
        // First apply is the pre-fetch clear (nil); the stream lands after the fetch.
        await waitUntil { host.appliedPrimary.last??.cues.isEmpty == false }
        XCTAssertEqual(host.appliedPrimary.first ?? nil, nil)   // cleared first
        XCTAssertFalse((host.appliedPrimary.last ?? nil)?.cues.isEmpty ?? true)
    }

    @MainActor
    func testLoadPrimaryWithoutSidecarClearsAndDoesNotFetch() async {
        let host = SpyOverlayHost()
        host.primarySubtitleSelectionID = 1
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadPrimary(embeddedTrack(1))
        // Only the synchronous clear happens; no async apply.
        XCTAssertEqual(host.appliedPrimary.count, 1)
        XCTAssertNil(host.appliedPrimary.first ?? nil)
    }

    @MainActor
    func testLoadPrimaryDropsResultWhenSelectionChangedMidFetch() async {
        let host = SpyOverlayHost()
        host.primarySubtitleSelectionID = 99   // never matches track id 1
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadPrimary(sidecarTrack(1))
        // Give the task time to run; the stale guard must prevent applying cues.
        await waitUntil(0.5) { host.appliedPrimary.count > 1 }
        XCTAssertFalse(host.appliedPrimary.contains { ($0?.cues.isEmpty == false) })
    }

    @MainActor
    func testLoadPrimaryRecordsDetectedLanguageForUntaggedTrack() async {
        let host = SpyOverlayHost()
        host.primarySubtitleSelectionID = 1
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadPrimary(sidecarTrack(1, language: nil))  // untagged → detection runs
        await waitUntil { host.detected[1] != nil }
        XCTAssertEqual(host.detected[1], "en")
        XCTAssertGreaterThanOrEqual(host.reloadCount, 1)    // relabel triggers a menu reload
    }

    @MainActor
    func testClearPrimaryClearsCues() {
        let host = SpyOverlayHost()
        let loader = makeLoader(host: host, data: Data())
        loader.clearPrimary()
        XCTAssertEqual(host.appliedPrimary.count, 1)
        XCTAssertNil(host.appliedPrimary.first ?? nil)
    }

    // MARK: - Secondary

    @MainActor
    func testLoadSecondaryAppliesCuesAndLoadedStatus() async {
        let host = SpyOverlayHost()
        host.secondarySubtitleSelectionID = 2
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadSecondary(sidecarTrack(2))
        await waitUntil { host.appliedSecondary.last??.cues.isEmpty == false }
        XCTAssertNil(host.appliedSecondary.first ?? nil)   // cleared first
        XCTAssertFalse((host.appliedSecondary.last ?? nil)?.cues.isEmpty ?? true)
        if case .loaded = host.secondaryStatuses.last { } else {
            XCTFail("expected .loaded status, got \(String(describing: host.secondaryStatuses.last))")
        }
    }

    @MainActor
    func testLoadSecondaryWithoutSidecarReportsUnavailable() {
        let host = SpyOverlayHost()
        host.secondarySubtitleSelectionID = 2
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadSecondary(embeddedTrack(2))
        XCTAssertEqual(host.secondaryStatuses.last, .unavailable)
        XCTAssertNil(host.appliedSecondary.last ?? nil)   // only the clear
    }

    @MainActor
    func testLoadSecondaryDropsResultWhenSelectionChangedMidFetch() async {
        let host = SpyOverlayHost()
        host.secondarySubtitleSelectionID = 99   // never matches track id 2
        let loader = makeLoader(host: host, data: Data(Self.vtt.utf8))
        loader.loadSecondary(sidecarTrack(2))
        await waitUntil(0.5) { host.secondaryStatuses.count > 1 }
        // Never applied a non-empty stream, never reported .loaded.
        XCTAssertFalse(host.appliedSecondary.contains { ($0?.cues.isEmpty == false) })
        XCTAssertFalse(host.secondaryStatuses.contains { if case .loaded = $0 { return true }; return false })
    }

    // MARK: - detectLanguage

    func testDetectLanguageReturnsCodeForSufficientText() {
        let cues = SubtitleCueParser.parseCues(Self.vtt)
        XCTAssertEqual(SubtitleOverlayLoader.detectLanguage(in: cues), "en")
    }

    func testDetectLanguageReturnsNilForTooLittleText() {
        let cues = SubtitleCueParser.parseCues("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n")
        XCTAssertNil(SubtitleOverlayLoader.detectLanguage(in: cues))
    }
}
#endif
