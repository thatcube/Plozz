import Foundation

/// A title's theme song resolved to a directly playable audio stream.
public struct ThemeMusic: Hashable, Sendable {
    public var itemID: String
    public var streamURL: URL
    public var title: String?

    public init(itemID: String, streamURL: URL, title: String? = nil) {
        self.itemID = itemID
        self.streamURL = streamURL
        self.title = title
    }
}
