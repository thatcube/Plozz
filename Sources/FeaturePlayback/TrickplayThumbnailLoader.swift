#if canImport(UIKit)
import UIKit
import CoreModels
import CoreNetworking

/// Loads, caches, and crops Jellyfin trickplay tiles into single scrubbing
/// thumbnails.
///
/// Designed so scrubbing never stutters: each tile image (a grid of many
/// thumbnails) is downloaded at most once and kept in memory, so moving the
/// scrub head only triggers a network fetch when crossing into a new tile —
/// every other frame is a cheap in-memory `CGImage` crop. Concurrent requests
/// for the same tile coalesce onto one download.
@MainActor
final class TrickplayThumbnailLoader: ScrubThumbnailProviding {
    private let manifest: TrickplayManifest
    private let session: URLSession
    private var tileCache: [URL: CGImage] = [:]
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    init(manifest: TrickplayManifest, session: URLSession = .shared) {
        self.manifest = manifest
        self.session = session
    }

    /// The cropped thumbnail for a playback position, or `nil` if unavailable.
    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        guard let tile = manifest.tile(forSeconds: seconds) else { return nil }
        let tileImage: CGImage?
        if let cached = tileCache[tile.url] {
            tileImage = cached
        } else {
            tileImage = await loadTile(tile.url)
        }
        guard let tileImage else { return nil }
        return crop(tileImage, to: tile)
    }

    /// Synchronous fast path: returns a thumbnail only if its tile is already
    /// cached, so the overlay can swap frames instantly while scrubbing without
    /// awaiting. Returns `nil` when the tile still needs downloading.
    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        guard let tile = manifest.tile(forSeconds: seconds),
              let tileImage = tileCache[tile.url] else { return nil }
        return crop(tileImage, to: tile)
    }

    private func loadTile(_ url: URL) async -> CGImage? {
        if let existing = inFlight[url] { return await existing.value }
        let session = self.session
        let task = Task<CGImage?, Never> {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    PlozzLog.playback.debug(
                        "Trickplay tile request failed status=\(http.statusCode) url=\(PlozzLog.redact(url: url))"
                    )
                    return nil
                }
                guard let image = UIImage(data: data)?.cgImage else {
                    PlozzLog.playback.debug("Trickplay tile decode failed url=\(PlozzLog.redact(url: url))")
                    return nil
                }
                return image
            } catch {
                PlozzLog.playback.debug(
                    "Trickplay tile request error=\(String(reflecting: error)) url=\(PlozzLog.redact(url: url))"
                )
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if let result { tileCache[url] = result }
        return result
    }

    private func crop(_ image: CGImage, to tile: TrickplayTile) -> CGImage? {
        let rect = CGRect(x: tile.cropX, y: tile.cropY, width: tile.cropWidth, height: tile.cropHeight)
        // The final tile's last row can be partially filled; clamp to bounds.
        let bounded = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !bounded.isNull, bounded.width > 1, bounded.height > 1 else { return nil }
        return image.cropping(to: bounded)
    }
}
#endif
