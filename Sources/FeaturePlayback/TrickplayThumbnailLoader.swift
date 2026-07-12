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
    private let authenticatedHTTPResolver:
        (any AuthenticatedHTTPResourceResolving)?
    private var tileCache: [ScrubPreviewResource: CGImage] = [:]
    private var inFlight: [ScrubPreviewResource: Task<CGImage?, Never>] = [:]

    init(
        manifest: TrickplayManifest,
        authenticatedHTTPResolver:
            (any AuthenticatedHTTPResourceResolving)? = nil,
        session: URLSession = .shared
    ) {
        self.manifest = manifest
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        self.session = session
    }

    /// The cropped thumbnail for a playback position, or `nil` if unavailable.
    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        guard let tile = manifest.tile(forSeconds: seconds) else { return nil }
        let tileImage: CGImage?
        if let cached = tileCache[tile.resource] {
            tileImage = cached
        } else {
            tileImage = await loadTile(tile.resource)
        }
        guard let tileImage else { return nil }
        return crop(tileImage, to: tile)
    }

    /// Synchronous fast path: returns a thumbnail only if its tile is already
    /// cached, so the overlay can swap frames instantly while scrubbing without
    /// awaiting. Returns `nil` when the tile still needs downloading.
    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        guard let tile = manifest.tile(forSeconds: seconds),
              let tileImage = tileCache[tile.resource] else { return nil }
        return crop(tileImage, to: tile)
    }

    private func loadTile(_ resource: ScrubPreviewResource) async -> CGImage? {
        if let existing = inFlight[resource] { return await existing.value }
        let session = self.session
        let resolver = authenticatedHTTPResolver
        let task = Task<CGImage?, Never> {
            do {
                let url: URL
                switch resource {
                case .publicURL(let source):
                    url = source.url
                case .authenticatedHTTP(let locator):
                    guard let resolver else { return nil }
                    url = try await resolver.resolve(locator)
                }
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
                let error = error as NSError
                PlozzLog.playback.debug(
                    "Trickplay tile request failed domain=\(error.domain) code=\(error.code)"
                )
                return nil
            }
        }
        inFlight[resource] = task
        let result = await task.value
        inFlight[resource] = nil
        if let result { tileCache[resource] = result }
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
