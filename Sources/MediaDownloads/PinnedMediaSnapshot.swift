import CoreModels
import Foundation

/// A small, PINNED copy of the metadata an offline card needs to render without
/// any server — captured at download time so browsing downloads works fully
/// offline.
///
/// ## Privacy / forward-compatibility (guardrail G2)
/// This snapshot must **never** persist a raw library/filesystem path or a
/// credential-bearing/expiring URL. Artwork is referenced only by
/// ``artworkFileName`` — the *relative leaf filename* of an image copied into the
/// download's own pinned folder (e.g. `poster.jpg`). That reference leaks nothing
/// about the user's library layout and never expires, and it stays valid if the
/// pinned folder is relocated wholesale.
public struct PinnedMediaSnapshot: Codable, Sendable, Hashable {
    public var title: String
    public var kind: MediaItemKind
    public var year: Int?
    /// Relative leaf filename of the poster/artwork inside this download's pinned
    /// folder, or `nil` when no artwork was captured. NEVER an absolute path or a
    /// server URL (see the type doc).
    public var artworkFileName: String?

    public init(
        title: String,
        kind: MediaItemKind,
        year: Int? = nil,
        artworkFileName: String? = nil
    ) {
        self.title = title
        self.kind = kind
        self.year = year
        self.artworkFileName = artworkFileName
    }
}

public extension PinnedMediaSnapshot {
    /// Builds a snapshot from a live `MediaItem`, copying only portable, non-secret
    /// fields (title/kind/year). Artwork is attached separately by the downloader
    /// once the image file has been pinned.
    init(item: MediaItem) {
        self.init(
            title: item.title,
            kind: item.kind,
            year: item.productionYear,
            artworkFileName: nil
        )
    }
}
