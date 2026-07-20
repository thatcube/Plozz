#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// Tests the pure engine-routing decision extracted from `PlayerViewModel`.
/// These pin the dual-engine promise: a network-file source always decodes
/// on-device, an image-based default subtitle reroutes an otherwise-native
/// source to Plozzigen so it can be drawn without a server burn-in, and every
/// image-sub reroute is gated on Plozzigen actually being wired in.
final class EngineSelectionTests: XCTestCase {
    private func request(
        item: MediaItem = MediaItem(id: "m1", title: "Movie", kind: .movie),
        streamURL: URL = URL(string: "https://example.test/movie.m3u8")!,
        subtitleTracks: [MediaTrack] = [],
        isTranscoding: Bool = false,
        sourceMetadata: MediaSourceMetadata? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            item: item, streamURL: streamURL,
            subtitleTracks: subtitleTracks,
            isTranscoding: isTranscoding,
            sourceMetadata: sourceMetadata)
    }

    private func imageSub(id: Int, language: String) -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "Sub \(id)",
            language: language, isImageBasedSubtitle: true)
    }

    private func route(
        _ request: PlaybackRequest,
        forceTranscode: Bool = false,
        plozzigenAvailable: Bool,
        rule: SubtitlePolicy.Rule = SubtitlePolicy.Rule()
    ) -> PlaybackEngineKind {
        EngineSelection.route(
            request: request,
            forceTranscode: forceTranscode,
            plozzigenAvailable: plozzigenAvailable,
            capabilities: .detected(),
            subtitleRule: rule)
    }

    // MARK: Network file

    func testDownloadedLocalFileRoutesToPlozzigenWhenAvailable() {
        let req = request(
            streamURL: URL(fileURLWithPath: "/downloads/media.mkv")
        )
        XCTAssertEqual(route(req, plozzigenAvailable: true), .plozzigen)
    }

    func testDownloadedLocalFileFallsBackToNativeWithoutPlozzigen() {
        let req = request(
            streamURL: URL(fileURLWithPath: "/downloads/media.mp4")
        )
        XCTAssertEqual(route(req, plozzigenAvailable: false), .native)
    }

    func testNetworkFileAlwaysRoutesToPlozzigen() throws {
        let identity = try RemoteFileIdentity(kind: .strongETag, value: "\"movie-v1\"")
        let representation = try RemoteFileRepresentation(
            size: 1_024, identity: identity, consistency: .stronglyBound)
        let locator = try NetworkFileLocator(
            accountID: "account", sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "Movies/Movie.mkv", representation: representation,
            formatHint: MediaFormatHint(container: "mkv", mimeType: "video/x-matroska"))
        var req = request()
        req.playbackSource = .networkFile(locator)

        // Even when Plozzigen were reported unavailable, a network file has no
        // other engine that can play it — the source itself forces the route.
        XCTAssertEqual(route(req, plozzigenAvailable: true), .plozzigen)
    }

    // MARK: Image-subtitle rerouting

    func testImageBasedDefaultSubtitleReroutesNativeToPlozzigen() {
        // No source facts → router picks native; the only English subtitle is
        // image-based and the rule wants English → reroute to Plozzigen.
        let req = request(subtitleTracks: [imageSub(id: 1, language: "en")])
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        XCTAssertEqual(route(req, plozzigenAvailable: true, rule: rule), .plozzigen)
    }

    func testImageSubtitleRerouteGatedOnPlozzigenAvailability() {
        // Same request, but Plozzigen isn't wired in → must stay native (no
        // engine can render the bitmap sub on-device, so we don't pretend).
        let req = request(subtitleTracks: [imageSub(id: 1, language: "en")])
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        XCTAssertEqual(route(req, plozzigenAvailable: false, rule: rule), .native)
    }

    func testTextSubtitleDefaultStaysNative() {
        let textSub = MediaTrack(id: 1, kind: .subtitle, displayTitle: "EN", language: "en")
        let req = request(subtitleTracks: [textSub])
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        XCTAssertEqual(route(req, plozzigenAvailable: true, rule: rule), .native)
    }

    func testTranscodedSourceStaysNative() {
        // A server transcode is a seekable HLS stream AVPlayer plays well; even
        // with an image sub present, a transcoded stream isn't rerouted.
        let req = request(subtitleTracks: [imageSub(id: 1, language: "en")], isTranscoding: true)
        let rule = SubtitlePolicy.Rule(mode: .all, preferredLanguages: ["en"])
        XCTAssertEqual(route(req, plozzigenAvailable: true, rule: rule), .native)
    }
}
#endif
