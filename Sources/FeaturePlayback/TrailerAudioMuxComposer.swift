import Foundation

/// Builds a tiny HLS master playlist that pairs a **video-only** stream with a
/// **separate audio-only** stream so `AVPlayer` muxes them itself, in sync,
/// during playback.
///
/// This is how Plozz plays higher-quality (e.g. 1080p H.264) YouTube trailers:
/// YouTube stopped serving a combined muxed stream above ~360p (itag 22 was
/// retired), so 1080p is only available as *adaptive* tracks — a video-only URL
/// and an audio-only URL. `AVPlayer` can't be handed two bare URLs, but it *can*
/// play an HLS master whose video variant carries an `EXT-X-MEDIA:TYPE=AUDIO`
/// alternate-audio rendition. Serving that master (via an
/// `AVAssetResourceLoaderDelegate`) makes AVPlayer fetch both real (https)
/// googlevideo segment URLs directly and interleave them on its own timeline —
/// no on-device remux, no third-party service.
///
/// Mirrors ``SubtitleHLSComposer``: each rendition is the *whole* remote file
/// referenced as one VOD segment (AVPlayer's tolerant single-file-segment
/// behaviour), and only the synthesized playlists use the private scheme; the
/// segment URIs point at the real streams.
///
/// Pure value type (no AVFoundation) so playlist generation is unit-testable on
/// any platform.
public struct TrailerAudioMuxComposer: Equatable, Sendable {
    /// Private scheme the resource loader claims. AVFoundation only routes schemes
    /// it can't handle itself to the delegate. Distinct from the subtitle
    /// composer's scheme so the two loaders never collide.
    public static let scheme = "plozztrailer"

    /// The video-only (picture, no sound) stream URL — the primary variant.
    public let videoURL: URL
    /// The audio-only stream URL — the alternate-audio rendition AVPlayer muxes in.
    public let audioURL: URL
    /// Media duration in seconds (read from the video-only asset up front).
    public let durationSeconds: Double

    public init(videoURL: URL, audioURL: URL, durationSeconds: Double) {
        self.videoURL = videoURL
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
    }

    // MARK: Custom-scheme URLs (also the routing keys for the loader)

    public static func masterURL() -> URL { url(path: "master.m3u8") }
    public static func videoPlaylistURL() -> URL { url(path: "video.m3u8") }
    public static func audioPlaylistURL() -> URL { url(path: "audio.m3u8") }

    private static func url(path: String) -> URL {
        URL(string: "\(scheme)://mux/\(path)")!
    }

    // MARK: Playlists

    /// The master playlist: one video variant tied to a single alternate-audio
    /// rendition group. `DEFAULT=YES,AUTOSELECT=YES` makes AVPlayer pick the audio
    /// with no user action; a nominal `BANDWIDTH` keeps AVPlayer happy on a
    /// single-variant master.
    public func masterPlaylist() -> String {
        [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(Self.audioPlaylistURL().absoluteString)\"",
            "#EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO=\"aud\"",
            Self.videoPlaylistURL().absoluteString
        ].joined(separator: "\n") + "\n"
    }

    /// The video media playlist: the whole video-only file as one VOD segment
    /// pointing at the real stream URL.
    public func videoMediaPlaylist() -> String {
        mediaPlaylist(segmentURL: videoURL.absoluteString)
    }

    /// The audio media playlist: the whole audio-only file as one VOD segment
    /// pointing at the real stream URL.
    public func audioMediaPlaylist() -> String {
        mediaPlaylist(segmentURL: audioURL.absoluteString)
    }

    private func mediaPlaylist(segmentURL: String) -> String {
        let target = max(1, Int(durationSeconds.rounded(.up)))
        return [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:\(formatDuration(durationSeconds)),",
            segmentURL,
            "#EXT-X-ENDLIST"
        ].joined(separator: "\n") + "\n"
    }

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }
}
