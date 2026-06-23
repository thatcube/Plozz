import Foundation

/// Online-trailer marking for `MediaItem`.
///
/// Local trailers (Jellyfin local trailer files, Plex local extras) are ordinary
/// `MediaItem`s that resolve through their owning provider's `playbackInfo(for:)`.
/// *Online* trailers have no backing server item — they carry a YouTube video id
/// (from a server-resolved remote trailer or a keyless search fallback) and are
/// played by extracting the stream in `ProviderTrailers`.
///
/// To keep that routing decision out of any one feature module, an online trailer
/// is just a `MediaItem` carrying its YouTube video id under a well-known
/// `providerIDs` key. The producer (`FeatureHome`) stamps it; the player router
/// (`AppShell`) reads `youTubeTrailerVideoID` to send it to the YouTube provider
/// instead of an account provider.
public extension MediaItem {
    /// `providerIDs` key whose value is the YouTube video id of an online trailer.
    static let youTubeTrailerProviderKey = "YouTubeTrailer"

    /// The YouTube video id when this item is an online trailer, else `nil`.
    var youTubeTrailerVideoID: String? {
        guard let id = providerIDs[Self.youTubeTrailerProviderKey], !id.isEmpty else { return nil }
        return id
    }

    /// Whether this item is an online (YouTube) trailer rather than a library item.
    var isYouTubeTrailer: Bool { youTubeTrailerVideoID != nil }

    /// Builds a playable online-trailer item for a YouTube `videoID`.
    ///
    /// The `id` is the YouTube video id (so the YouTube provider can resolve it)
    /// and the id is also recorded under ``youTubeTrailerProviderKey`` as the
    /// routing marker. `kind` is `.video` so it threads through the player like
    /// any other leaf.
    static func youTubeTrailer(
        videoID: String,
        title: String,
        parentTitle: String? = nil,
        runtime: TimeInterval? = nil,
        posterURL: URL? = nil
    ) -> MediaItem {
        MediaItem(
            id: videoID,
            title: title,
            kind: .video,
            parentTitle: parentTitle,
            runtime: runtime,
            posterURL: posterURL,
            providerIDs: [youTubeTrailerProviderKey: videoID]
        )
    }

    /// Builds a playable online-trailer item from a full YouTube URL, or `nil`
    /// when the URL isn't a recognizable YouTube link. This is how *server*
    /// remote trailers (Jellyfin `RemoteTrailers`, Plex remote extras) become
    /// playable: the server hands us a YouTube watch URL it resolved with its own
    /// metadata key, and we extract the video id to route through the keyless
    /// YouTube trailer provider.
    static func youTubeTrailer(
        fromURL urlString: String,
        title: String,
        parentTitle: String? = nil,
        posterURL: URL? = nil
    ) -> MediaItem? {
        guard let videoID = youTubeVideoID(fromURL: urlString) else { return nil }
        return youTubeTrailer(videoID: videoID, title: title, parentTitle: parentTitle, posterURL: posterURL)
    }

    /// Extracts a YouTube video id from any common YouTube URL form, or `nil`.
    ///
    /// Handles `youtube.com/watch?v=ID` (with extra params), short
    /// `youtu.be/ID`, `youtube.com/embed/ID`, `youtube.com/shorts/ID`, and the
    /// `youtube-nocookie.com` privacy host. A bare 11-char id is accepted as-is.
    static func youTubeVideoID(fromURL urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        func validID(_ candidate: Substring?) -> String? {
            guard let candidate else { return nil }
            let id = String(candidate)
            // YouTube ids are 11 chars of [A-Za-z0-9_-].
            guard id.count == 11,
                  id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            else { return nil }
            return id
        }

        // Bare id (no scheme / slashes).
        if !trimmed.contains("/"), let bare = validID(Substring(trimmed)) {
            return bare
        }

        guard let components = URLComponents(string: trimmed) else { return nil }
        let host = (components.host ?? "").lowercased()

        // youtu.be/<id>
        if host.hasSuffix("youtu.be") {
            let path = components.path.drop(while: { $0 == "/" })
            return validID(path.prefix(while: { $0 != "/" }))
        }

        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else {
            return nil
        }

        // /watch?v=<id>
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return validID(Substring(v))
        }

        // /embed/<id>, /shorts/<id>, /v/<id>
        let segments = components.path.split(separator: "/")
        if let marker = segments.firstIndex(where: { $0 == "embed" || $0 == "shorts" || $0 == "v" }),
           segments.index(after: marker) < segments.endIndex {
            return validID(segments[segments.index(after: marker)])
        }
        return nil
    }
}
