#if canImport(UIKit)
import UIKit
import ImageIO
import CoreModels

/// Process-wide, in-memory cache of *decoded* artwork images, keyed by source URL
/// and target variant.
///
/// `URLCache.shared` keeps recently-fetched image *bytes* warm, but reading and
/// decoding those bytes is still asynchronous, so a card scrolled into view would
/// render a gray placeholder for a frame or two before its image appears — most
/// visible while holding RIGHT to blast through an episode rail. This cache lets a
/// card read its already-decoded image *synchronously* on first render (no async
/// hop, no gray frame), and lets a rail prefetch/decode upcoming cards ahead of
/// scroll so their art is ready the instant they appear.
///
/// Images are force-decoded off the main thread (`preparingForDisplay`) before
/// being stored, so handing one to SwiftUI never triggers a main-thread decode.
public final class ArtworkImageCache: @unchecked Sendable {
    public static let shared = ArtworkImageCache()

    private struct CacheKey: Hashable {
        let url: URL
        let variant: ArtworkImageVariant

        var cacheKey: NSString {
            variant.cacheKey(for: url) as NSString
        }
    }

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    /// Dedicated, bounded queue for the *synchronous* image decode
    /// (`CGImageSourceCreateThumbnailAtIndex` / `preparingForDisplay`). This work
    /// is CPU-bound, and running it inside `Task.detached` executes it directly on
    /// Swift's small cooperative thread pool (only ~2-3 threads on tvOS). A scroll
    /// burst through a library — especially thumbnail-less cells that try several
    /// candidate URLs — would then fire many concurrent decodes that occupy every
    /// cooperative thread, starving unrelated `async` continuations (a foreground
    /// `provider.item`/cross-server `search`, even `Task.sleep` timeouts) for
    /// seconds. Moving decode onto its own bounded `OperationQueue` keeps that CPU
    /// off the cooperative pool entirely, so artwork can never freeze the app.
    /// Foreground decode lane for artwork the user is actually looking at (a
    /// visible card or the detail hero awaiting `image(for:)`). Runs at
    /// `.userInitiated` so it is scheduled ahead of background warming.
    private static let decodeQueueFG: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()
    /// Background decode lane for prefetch/warm work (rail prewarm, season
    /// still prefetch). Kept fully separate from the foreground lane so a
    /// prewarm storm can never make a visible card's decode wait behind it.
    private static let decodeQueueBG: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
        return queue
    }()
    /// One coalesced, cancellable load of a single URL+variant. `waiters` counts
    /// the live `image(for:)` callers awaiting it; when the last waiter's task is
    /// cancelled (e.g. its card scrolled off-screen) the underlying download +
    /// decode is cancelled too, freeing the artwork connection it was holding for
    /// whatever the user is actually looking at now.
    private final class ImageLoad {
        var task: Task<UIImage?, Never>!
        var waiters: Int = 0
    }
    /// In-flight image loads keyed by URL+variant so a card's own load and the
    /// rail's prefetch never decode the same target twice.
    private var inFlight: [CacheKey: ImageLoad] = [:]

    private init() {
        // Decoded landscape/poster thumbnails are small; cap retained pixels so the
        // cache stays bounded on long seasons (NSCache evicts under memory pressure
        // regardless).
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// The decoded image for `url`+`variant` if one is already resident, read
    /// synchronously.
    public func cachedImage(for url: URL, variant: ArtworkImageVariant = .original) -> UIImage? {
        cache.object(forKey: CacheKey(url: url, variant: variant).cacheKey)
    }

    /// Returns the decoded image for `url`+`variant`, serving a cached copy
    /// immediately when present and otherwise downloading + decoding it once
    /// (coalescing concurrent callers). Result is stored for synchronous reuse via
    /// `cachedImage(for:variant:)`.
    @discardableResult
    public func image(for url: URL, variant: ArtworkImageVariant = .original, background: Bool = false) async -> UIImage? {
        if let cached = cachedImage(for: url, variant: variant) { return cached }
        let key = CacheKey(url: url, variant: variant)
        let load = registerWaiter(for: key, background: background)
        return await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            unregisterWaiter(load, for: key)
        }
    }

    /// Warms the cache for `url`+`variant` without awaiting the result —
    /// fire-and-forget prefetch used by rails to decode upcoming cards ahead of
    /// scroll. Bounded by the shared background-warm limiter so a prewarm/scroll
    /// burst can't flood the artwork connection pool and starve foreground art.
    public func prefetch(_ url: URL, variant: ArtworkImageVariant = .original) {
        guard cachedImage(for: url, variant: variant) == nil else { return }
        Task.detached(priority: .utility) {
            await ArtworkSession.warmLimiter.run {
                _ = await ArtworkImageCache.shared.image(for: url, variant: variant, background: true)
            }
        }
    }

    private func registerWaiter(for key: CacheKey, background: Bool) -> ImageLoad {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[key] {
            existing.waiters += 1
            return existing
        }
        let load = ImageLoad()
        load.waiters = 1
        // Detached so the download + decode never inherit (and block) the MainActor
        // when kicked off from a card's `onAppear`/prefetch. The download is a
        // cancellable URLSession call and the decode runs off the cooperative pool,
        // so cancelling this task (last waiter gone) both stops the in-flight
        // transfer — freeing its connection — and skips the decode.
        load.task = Task<UIImage?, Never>.detached(priority: .utility) { [weak self, weak load] in
            guard let self else { return nil }
            defer { self.clearInFlight(key, ifMatches: load) }
            if Task.isCancelled { return nil }
            guard let data = await Self.downloadData(key.url) else { return nil }
            if Task.isCancelled { return nil }
            guard let image = await Self.decodeImageOffPool(from: data, variant: key.variant, background: background) else {
                return nil
            }
            self.store(image, for: key)
            return image
        }
        inFlight[key] = load
        return load
    }

    private func unregisterWaiter(_ load: ImageLoad, for key: CacheKey) {
        lock.lock()
        defer { lock.unlock() }
        load.waiters -= 1
        if load.waiters <= 0 {
            load.task.cancel()
            if inFlight[key] === load { inFlight[key] = nil }
        }
    }

    private func store(_ image: UIImage, for key: CacheKey) {
        let scale = image.scale
        let cost = Int(image.size.width * scale * image.size.height * scale * 4)
        cache.setObject(image, forKey: key.cacheKey, cost: max(cost, 1))
    }

    private func clearInFlight(_ key: CacheKey, ifMatches load: ImageLoad?) {
        lock.lock()
        if let load, inFlight[key] === load {
            inFlight[key] = nil
        }
        lock.unlock()
    }

    private static func downloadData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await ArtworkSession.shared.data(from: url) else {
            return nil
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return data
    }

    /// Runs the synchronous decode on a dedicated bounded queue instead of the
    /// Swift cooperative pool, bridging back via a continuation. Foreground
    /// decodes (visible card / detail hero) use the higher-priority lane so they
    /// never wait behind a background prewarm storm. Keeps artwork CPU off the
    /// cooperative pool so it can't starve unrelated `async` continuations.
    private static func decodeImageOffPool(from data: Data, variant: ArtworkImageVariant, background: Bool) async -> UIImage? {
        let queue = background ? decodeQueueBG : decodeQueueFG
        return await withCheckedContinuation { continuation in
            queue.addOperation {
                let img = decodeImage(from: data, variant: variant)
                continuation.resume(returning: img)
            }
        }
    }

    private static func decodeImage(from data: Data, variant: ArtworkImageVariant) -> UIImage? {
        let image: UIImage?
        if let maxPixelSize = variant.maxPixelSize {
            image = downsampledImage(from: data, maxPixelSize: maxPixelSize)
        } else {
            image = UIImage(data: data)
        }
        guard let image else { return nil }
        // Force-decode now (off the main thread) so the cached image is render-ready.
        return image.preparingForDisplay() ?? image
    }

    private static func downsampledImage(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
