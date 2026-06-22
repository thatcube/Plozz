import Foundation

/// One subtitle track to inject into the synthesized HLS playlist so it appears
/// in the native `AVPlayerViewController` picker even during direct play.
///
/// Pure value type (no AVFoundation) so the playlist generation can be unit
/// tested on any platform.
public struct InjectableSubtitle: Equatable, Sendable {
    /// Provider-native stream index; also the stable id used in the custom-scheme
    /// URLs the resource loader routes.
    public var index: Int
    /// Human-readable name shown in the picker.
    public var name: String
    /// BCP-47 / ISO language tag for the `LANGUAGE` attribute, if known.
    public var languageTag: String?
    public var isDefault: Bool
    public var isForced: Bool
    /// Absolute provider URL that returns the subtitle text (WebVTT, or SRT which
    /// is normalised to WebVTT before being handed to the player).
    public var sourceURL: URL

    public init(
        index: Int,
        name: String,
        languageTag: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        sourceURL: URL
    ) {
        self.index = index
        self.name = name
        self.languageTag = languageTag
        self.isDefault = isDefault
        self.isForced = isForced
        self.sourceURL = sourceURL
    }
}

/// Builds a tiny HLS master playlist that wraps a single direct-play video file
/// as one VOD segment and adds `EXT-X-MEDIA TYPE=SUBTITLES` renditions for each
/// provider subtitle. Serving this (via an `AVAssetResourceLoaderDelegate`)
/// makes external/text subtitles selectable in the native player **without**
/// transcoding the video.
///
/// All generated playlists and the subtitle payloads use a private custom URL
/// scheme so the resource loader can intercept and synthesize them; only the
/// video segment points at the real (https) stream URL, which AVPlayer loads
/// directly.
public struct SubtitleHLSComposer: Equatable, Sendable {
    /// Private scheme the resource loader claims. Any non-standard scheme works;
    /// AVFoundation only routes schemes it can't handle itself to the delegate.
    public static let scheme = "plozzcc"

    public let videoURL: URL
    public let durationSeconds: Double
    public let subtitles: [InjectableSubtitle]

    public init(videoURL: URL, durationSeconds: Double, subtitles: [InjectableSubtitle]) {
        self.videoURL = videoURL
        self.durationSeconds = durationSeconds
        self.subtitles = subtitles
    }

    // MARK: Custom-scheme URLs (also the routing keys for the loader)

    public static func masterURL() -> URL { url(path: "master.m3u8") }
    public static func videoPlaylistURL() -> URL { url(path: "video.m3u8") }
    public static func subtitlePlaylistURL(index: Int) -> URL { url(path: "sub-\(index).m3u8") }
    public static func subtitlePayloadURL(index: Int) -> URL { url(path: "sub-\(index).vtt") }

    private static func url(path: String) -> URL {
        URL(string: "\(scheme)://cc/\(path)")!
    }

    // MARK: Playlists

    /// The master playlist: one video variant plus a SUBTITLES rendition group.
    public func masterPlaylist() -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3"]
        for subtitle in subtitles {
            var attrs = [
                "TYPE=SUBTITLES",
                "GROUP-ID=\"subs\"",
                "NAME=\"\(escapeQuotes(subtitle.name))\"",
                "DEFAULT=\(subtitle.isDefault ? "YES" : "NO")",
                "AUTOSELECT=YES",
                "FORCED=\(subtitle.isForced ? "YES" : "NO")"
            ]
            if let tag = subtitle.languageTag, !tag.isEmpty {
                attrs.append("LANGUAGE=\"\(escapeQuotes(tag))\"")
            }
            attrs.append("URI=\"\(Self.subtitlePlaylistURL(index: subtitle.index).absoluteString)\"")
            lines.append("#EXT-X-MEDIA:" + attrs.joined(separator: ","))
        }
        // A nominal bandwidth keeps AVPlayer happy; the real bitrate is irrelevant
        // because there's a single variant. SUBTITLES ties the renditions on.
        let subtitlesAttr = subtitles.isEmpty ? "" : ",SUBTITLES=\"subs\""
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=8000000\(subtitlesAttr)")
        lines.append(Self.videoPlaylistURL().absoluteString)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The video media playlist: the whole direct-play file as a single VOD
    /// segment pointing at the real stream URL.
    public func videoMediaPlaylist() -> String {
        mediaPlaylist(segmentURL: videoURL.absoluteString)
    }

    /// A subtitle media playlist: the whole WebVTT as a single VOD segment,
    /// pointing at the custom-scheme payload URL the loader fulfils.
    public func subtitleMediaPlaylist(index: Int) -> String {
        mediaPlaylist(segmentURL: Self.subtitlePayloadURL(index: index).absoluteString)
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

    private func escapeQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
    }

    private func formatDuration(_ seconds: Double) -> String {
        String(format: "%.3f", max(0, seconds))
    }
}
