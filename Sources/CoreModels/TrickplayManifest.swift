import Foundation

/// A provider-agnostic manifest of scrubbing-preview ("trickplay") thumbnails
/// for one playable item.
///
/// Servers (Jellyfin today, Plex later) pre-generate a strip of thumbnails at a
/// fixed time interval and pack them into a small number of grid "tile" images.
/// The custom player uses this to show Infuse-style scene previews while the
/// viewer scrubs — without decoding the live stream.
///
/// Geometry recap (matches Jellyfin's trickplay model):
///  * a single thumbnail is `thumbnailWidth × thumbnailHeight` px;
///  * each tile image packs `tileColumns × tileRows` thumbnails in row-major order;
///  * thumbnail *n* covers playback time `n × intervalMs` … `(n+1) × intervalMs`;
///  * `tileURLs[i]` is the i-th tile image (the tiles in playback order).
public struct TrickplayManifest: Hashable, Sendable {
    /// Width of a single thumbnail, in pixels.
    public var thumbnailWidth: Int
    /// Height of a single thumbnail, in pixels.
    public var thumbnailHeight: Int
    /// Number of thumbnails per row within a tile image.
    public var tileColumns: Int
    /// Number of thumbnails per column within a tile image.
    public var tileRows: Int
    /// Total number of thumbnails across every tile.
    public var thumbnailCount: Int
    /// Milliseconds of playback between consecutive thumbnails.
    public var intervalMs: Int
    /// The tile images, in playback order. Index with `tileIndex(forThumbnail:)`.
    public var tileURLs: [URL]

    public init(
        thumbnailWidth: Int,
        thumbnailHeight: Int,
        tileColumns: Int,
        tileRows: Int,
        thumbnailCount: Int,
        intervalMs: Int,
        tileURLs: [URL]
    ) {
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.tileColumns = tileColumns
        self.tileRows = tileRows
        self.thumbnailCount = thumbnailCount
        self.intervalMs = intervalMs
        self.tileURLs = tileURLs
    }

    /// Number of thumbnails packed into one tile image.
    public var thumbnailsPerTile: Int { max(1, tileColumns * tileRows) }

    /// Whether this manifest can actually resolve any thumbnail.
    public var isUsable: Bool {
        thumbnailCount > 0
            && intervalMs > 0
            && thumbnailWidth > 0
            && thumbnailHeight > 0
            && !tileURLs.isEmpty
    }

    /// The thumbnail index covering a playback position (clamped to range).
    public func thumbnailIndex(forSeconds seconds: TimeInterval) -> Int {
        guard intervalMs > 0, thumbnailCount > 0 else { return 0 }
        let ms = max(0, seconds) * 1000
        let index = Int(ms / Double(intervalMs))
        return min(max(0, index), thumbnailCount - 1)
    }

    /// Resolves the tile image + crop rectangle for a playback position, or
    /// `nil` if this manifest can't supply a thumbnail.
    public func tile(forSeconds seconds: TimeInterval) -> TrickplayTile? {
        guard isUsable else { return nil }
        let thumbnailIndex = thumbnailIndex(forSeconds: seconds)
        let perTile = thumbnailsPerTile
        let tileIndex = thumbnailIndex / perTile
        guard tileURLs.indices.contains(tileIndex) else { return nil }
        let indexInTile = thumbnailIndex % perTile
        let column = indexInTile % tileColumns
        let row = indexInTile / tileColumns
        return TrickplayTile(
            url: tileURLs[tileIndex],
            cropX: column * thumbnailWidth,
            cropY: row * thumbnailHeight,
            cropWidth: thumbnailWidth,
            cropHeight: thumbnailHeight
        )
    }
}

/// A resolved trickplay thumbnail: which tile image to load and the pixel
/// rectangle to crop out of it.
public struct TrickplayTile: Hashable, Sendable {
    /// The tile image to download (cache by this URL).
    public var url: URL
    /// Left edge of the thumbnail within the tile image, in pixels.
    public var cropX: Int
    /// Top edge of the thumbnail within the tile image, in pixels.
    public var cropY: Int
    /// Thumbnail width, in pixels.
    public var cropWidth: Int
    /// Thumbnail height, in pixels.
    public var cropHeight: Int

    public init(url: URL, cropX: Int, cropY: Int, cropWidth: Int, cropHeight: Int) {
        self.url = url
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
    }
}
