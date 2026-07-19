#if canImport(UIKit)
import CoreGraphics
import CoreModels
import CoreNetworking
import Foundation
import Observation

/// Shared presentation coordinator for Jellyfin/Emby trickplay tiles and Plex
/// BIF previews. Platform-specific controls only provide the scrub position.
@MainActor
@Observable
public final class ScrubPreviewCoordinator {
    public private(set) var image: CGImage?

    @ObservationIgnored
    private let loader: any ScrubThumbnailProviding
    @ObservationIgnored
    private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored
    var onImageChange: ((CGImage?) -> Void)?

    public init?(
        source: ScrubPreviewSource?,
        authenticatedHTTPResolver:
            (any AuthenticatedHTTPResourceResolving)? = nil
    ) {
        guard let source, source.isUsable else { return nil }
        switch source {
        case .tiled(let manifest):
            loader = TrickplayThumbnailLoader(
                manifest: manifest,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
        case .plexBIF(let resource):
            loader = PlexBIFThumbnailLoader(
                resource: resource,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
        }
    }

    public func prefetch() {
        loader.prefetch()
    }

    /// Updates the visible frame and returns whether it was already in memory.
    @discardableResult
    public func update(for seconds: TimeInterval) -> Bool {
        if let cached = loader.cachedThumbnail(forSeconds: seconds) {
            thumbnailTask?.cancel()
            setImage(cached)
            return true
        }

        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            let requestedImage = await loader.thumbnail(forSeconds: seconds)
            guard !Task.isCancelled else { return }
            setImage(requestedImage)
        }
        return false
    }

    public func clear() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        setImage(nil)
    }

    private func setImage(_ image: CGImage?) {
        self.image = image
        onImageChange?(image)
    }
}
#endif
