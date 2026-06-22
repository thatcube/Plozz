import Foundation

/// Online-trailer marking for `MediaItem`.
///
/// Local trailers (Jellyfin local trailer files, Plex local extras) are ordinary
/// `MediaItem`s that resolve through their owning provider's `playbackInfo(for:)`.
/// *Online* trailers have no backing server item — they come from TMDb as a
/// YouTube video id and are played by extracting the stream in `ProviderTrailers`.
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
}
