import XCTest
import CoreModels
@testable import FeaturePlayback

final class SubtitleHLSComposerTests: XCTestCase {
    private func subtitle(_ index: Int, name: String, lang: String?, isDefault: Bool = false, isForced: Bool = false) -> InjectableSubtitle {
        InjectableSubtitle(
            index: index,
            name: name,
            languageTag: lang,
            isDefault: isDefault,
            isForced: isForced,
            sourceURL: URL(string: "https://server/Subtitles/\(index).vtt")!
        )
    }

    @MainActor
    final class AuthenticatedSubtitleResolutionTests: XCTestCase {
        func testNativeEngineResolvesSubtitleAtLoadBoundary() async throws {
            let locator = try AuthenticatedHTTPPlaybackLocator(
                provider: .jellyfin,
                accountID: "account",
                credentialRevision: CredentialRevision(),
                itemID: "item",
                mediaSourceID: "source",
                deliveryMode: .directFile,
                purpose: .subtitle,
                resource: try AuthenticatedHTTPResource(
                    pathBase: .configuredBaseURL,
                    path: "Videos/item/source/Subtitles/2/0/Stream.vtt"
                )
            )
            let resolver = RecordingSubtitleResolver(
                resolvedURL: URL(fileURLWithPath: "/tmp/subtitle.vtt")
            )
            let engine = NativeVideoEngine(
                authenticatedHTTPResolver: resolver
            )
            var request = PlaybackRequest(
                item: MediaItem(
                    id: "item",
                    title: "Movie",
                    kind: .movie,
                    runtime: 120
                ),
                streamURL: URL(string: "https://media.example/movie.mp4")!
            )
            request.subtitleTracks = [
                MediaTrack(
                    id: 2,
                    kind: .subtitle,
                    displayTitle: "English",
                    language: "en",
                    codec: "srt",
                    deliverySource: .authenticatedHTTP(locator)
                )
            ]

            await engine.load(request: request, startPosition: 0)

            XCTAssertEqual(resolver.locators, [locator])
            await engine.stop()
        }
    }

    @MainActor
    private final class RecordingSubtitleResolver:
        AuthenticatedHTTPResourceResolving
    {
        let resolvedURL: URL
        private(set) var locators: [AuthenticatedHTTPPlaybackLocator] = []

        init(resolvedURL: URL) {
            self.resolvedURL = resolvedURL
        }

        func resolve(
            _ locator: AuthenticatedHTTPPlaybackLocator
        ) async throws -> URL {
            locators.append(locator)
            return resolvedURL
        }
    }

    func testMasterListsEachSubtitleAndTiesGroup() {
        let composer = SubtitleHLSComposer(
            videoURL: URL(string: "https://server/stream.mp4?static=true")!,
            durationSeconds: 1200,
            subtitles: [
                subtitle(2, name: "English", lang: "en", isDefault: true),
                subtitle(3, name: "Forced", lang: "en", isForced: true)
            ]
        )
        let master = composer.masterPlaylist()

        XCTAssertTrue(master.hasPrefix("#EXTM3U"))
        XCTAssertEqual(master.components(separatedBy: "#EXT-X-MEDIA:").count - 1, 2)
        XCTAssertTrue(master.contains("TYPE=SUBTITLES"))
        XCTAssertTrue(master.contains("GROUP-ID=\"subs\""))
        XCTAssertTrue(master.contains("NAME=\"English\""))
        XCTAssertTrue(master.contains("LANGUAGE=\"en\""))
        XCTAssertTrue(master.contains("DEFAULT=YES"))
        XCTAssertTrue(master.contains("FORCED=YES"))
        XCTAssertTrue(master.contains("SUBTITLES=\"subs\""))
        // Subtitle rendition URIs and the video variant use the custom scheme.
        XCTAssertTrue(master.contains("URI=\"plozzcc://cc/sub-2.m3u8\""))
        XCTAssertTrue(master.contains("plozzcc://cc/video.m3u8"))
    }

    func testMasterWithoutSubtitlesOmitsGroup() {
        let composer = SubtitleHLSComposer(
            videoURL: URL(string: "https://server/stream.mp4")!,
            durationSeconds: 60,
            subtitles: []
        )
        let master = composer.masterPlaylist()
        XCTAssertFalse(master.contains("SUBTITLES="))
        XCTAssertFalse(master.contains("#EXT-X-MEDIA:"))
    }

    func testVideoMediaPlaylistWrapsRealURLAsSingleSegment() {
        let video = URL(string: "https://server/stream.mp4?static=true&api_key=abc")!
        let composer = SubtitleHLSComposer(videoURL: video, durationSeconds: 90.5, subtitles: [])
        let playlist = composer.videoMediaPlaylist()

        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.contains("#EXT-X-TARGETDURATION:91"))
        XCTAssertTrue(playlist.contains("#EXTINF:90.500,"))
        XCTAssertTrue(playlist.contains(video.absoluteString))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
    }

    func testSubtitleMediaPlaylistPointsAtPayloadURL() {
        let composer = SubtitleHLSComposer(
            videoURL: URL(string: "https://server/stream.mp4")!,
            durationSeconds: 100,
            subtitles: [subtitle(5, name: "Spanish", lang: "es")]
        )
        let playlist = composer.subtitleMediaPlaylist(index: 5)
        XCTAssertTrue(playlist.contains("plozzcc://cc/sub-5.vtt"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
    }

    func testNameQuotesAreEscaped() {
        let composer = SubtitleHLSComposer(
            videoURL: URL(string: "https://server/stream.mp4")!,
            durationSeconds: 100,
            subtitles: [subtitle(1, name: "Director\"s cut", lang: nil)]
        )
        let master = composer.masterPlaylist()
        XCTAssertTrue(master.contains("NAME=\"Director's cut\""))
        XCTAssertFalse(master.contains("Director\"s cut"))
    }
}
