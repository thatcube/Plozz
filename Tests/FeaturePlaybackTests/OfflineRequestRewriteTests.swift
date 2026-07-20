#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback

/// Guardrail tests for the offline-download playback hook
/// (`PlayerViewModel.applyingOfflineRewrite`): when a completed local copy exists
/// the request must be rewritten to the local file in the field BOTH engines read,
/// route to the SAME engine a normal local play of that file would, and when NO
/// local copy exists it must be a strict, byte-identical no-op.
final class OfflineRequestRewriteTests: XCTestCase {

    private func localURL() -> URL {
        URL(fileURLWithPath: "/tmp/plozz/downloads/movie.mkv")
    }

    private func networkFileLocator() throws -> NetworkFileLocator {
        let identity = try RemoteFileIdentity(kind: .strongETag, value: "\"movie-v1\"")
        let representation = try RemoteFileRepresentation(
            size: 1_024, identity: identity, consistency: .stronglyBound)
        return try NetworkFileLocator(
            accountID: "account", sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "Movies/Movie.mkv", representation: representation,
            formatHint: MediaFormatHint(container: "mkv", mimeType: "video/x-matroska"))
    }

    private func route(_ request: PlaybackRequest) -> PlaybackEngineKind {
        EngineSelection.route(
            request: request,
            forceTranscode: false,
            plozzigenAvailable: true,
            capabilities: .detected(),
            subtitleRule: SubtitlePolicy.Rule())
    }

    // MARK: prefers-local

    func testRewriteMovesLocalFileIntoStreamURLAndClearsNetworkSource() throws {
        let item = MediaItem(id: "m1", title: "Movie", kind: .movie)
        var request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!,
            isTranscoding: true)
        request.playbackSource = .networkFile(try networkFileLocator())
        request.originalFileSource = .networkFile(try networkFileLocator())
        request.externalAudioURL = URL(string: "https://example.test/audio.m4a")!

        let rewritten = PlayerViewModel.applyingOfflineRewrite(to: request, localURL: localURL())

        // Correct field: the local file lands in the legacy `streamURL` field that
        // BOTH engines consume for a direct file; every network/managed source is
        // cleared and it is a non-manifest direct play.
        XCTAssertEqual(rewritten.streamURL, localURL())
        XCTAssertNil(rewritten.playbackSource)
        XCTAssertNil(rewritten.originalFileSource)
        XCTAssertNil(rewritten.externalAudioURL)
        XCTAssertNil(rewritten.localRemuxSource)
        XCTAssertFalse(rewritten.isManifestStream)
        XCTAssertFalse(rewritten.isTranscoding)
        XCTAssertEqual(rewritten.deliveryMode, .directPlay)
    }

    func testRewrittenRequestRoutesLikeANormalLocalPlay_native() throws {
        let item = MediaItem(id: "m1", title: "Movie", kind: .movie)
        // A source with NO on-device-decode facts routes to the native engine.
        var networkRequest = PlaybackRequest(
            item: item, streamURL: URL(string: "https://example.test/movie.m3u8")!)
        networkRequest.playbackSource = .networkFile(try networkFileLocator())

        let rewritten = PlayerViewModel.applyingOfflineRewrite(to: networkRequest, localURL: localURL())
        let baseline = PlaybackRequest(item: item, streamURL: localURL())

        // Same engine decision as constructing the local play directly.
        XCTAssertEqual(route(rewritten), route(baseline))
    }

    func testRewrittenRequestRoutesLikeANormalLocalPlay_onDeviceDecode() throws {
        let item = MediaItem(id: "m1", title: "Movie", kind: .movie)
        // 10-bit H.264 forces the on-device (Plozzigen) engine; the rewrite must
        // route identically to a direct local play carrying the same facts, with the
        // file in the shared `streamURL` field the engine reads.
        let metadata = MediaSourceMetadata(
            container: "mkv",
            video: MediaSourceMetadata.VideoStream(codec: "h264", bitDepth: 10))
        var networkRequest = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!,
            sourceMetadata: metadata)
        networkRequest.playbackSource = .networkFile(try networkFileLocator())

        let rewritten = PlayerViewModel.applyingOfflineRewrite(to: networkRequest, localURL: localURL())
        let baseline = PlaybackRequest(item: item, streamURL: localURL(), sourceMetadata: metadata)

        XCTAssertEqual(rewritten.streamURL, localURL())
        XCTAssertEqual(route(rewritten), route(baseline))
    }

    // MARK: no-op-when-empty

    func testNoLocalCopyIsByteIdenticalNoOp() throws {
        let item = MediaItem(id: "m1", title: "Movie", kind: .movie)
        var request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!,
            isTranscoding: true)
        request.playbackSource = .networkFile(try networkFileLocator())

        let result = PlayerViewModel.applyingOfflineRewrite(to: request, localURL: nil)
        XCTAssertEqual(result, request)
    }

    @MainActor
    func testOfflineFastPathOnlyAppliesToTheRequestedItem() {
        let current = MediaItem(id: "episode-1", title: "Episode 1", kind: .episode)

        XCTAssertTrue(
            PlayerViewModel.shouldUseOfflineFastPath(
                offlineItem: current,
                requestedItemID: "episode-1",
                forceTranscode: false
            )
        )
        XCTAssertFalse(
            PlayerViewModel.shouldUseOfflineFastPath(
                offlineItem: current,
                requestedItemID: "episode-2",
                forceTranscode: false
            )
        )
        XCTAssertFalse(
            PlayerViewModel.shouldUseOfflineFastPath(
                offlineItem: current,
                requestedItemID: "episode-1",
                forceTranscode: true
            )
        )
    }
}
#endif
