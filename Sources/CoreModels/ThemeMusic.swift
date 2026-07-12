import Foundation

/// A title's theme song with a credential-free playback source.
public struct ThemeMusic: Hashable, Sendable {
    public var itemID: String
    public var playbackSource: PlaybackSource
    public var title: String?

    public init(
        itemID: String,
        playbackSource: PlaybackSource,
        title: String? = nil
    ) {
        self.itemID = itemID
        self.playbackSource = playbackSource
        self.title = title
    }
}
