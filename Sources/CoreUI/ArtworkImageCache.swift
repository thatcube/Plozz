#if canImport(UIKit)
import UIKit
import ImageIO

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
    /// In-flight image loads keyed by URL+variant so a card's own load and the
    /// rail's prefetch never decode the same target twice.
    private var inFlight: [CacheKey: Task<UIImage?, Never>] = [:]
    /// In-flight byte fetches keyed by URL so poster/landscape/hero requests for
    /// the same source coalesce onto one network transfer.
    private var dataInFlight: [URL: Task<Data?, Never>] = [:]

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
    public func image(for url: URL, variant: ArtworkImageVariant = .original) async -> UIImage? {
        if let cached = cachedImage(for: url, variant: variant) { return cached }
        let key = CacheKey(url: url, variant: variant)
        let task = loadTask(for: key)
        return await task.value
    }

    /// Warms the cache for `url`+`variant` without awaiting the result —
    /// fire-and-forget prefetch used by rails to decode upcoming cards ahead of
    /// scroll.
    public func prefetch(_ url: URL, variant: ArtworkImageVariant = .original) {
        guard cachedImage(for: url, variant: variant) == nil else { return }
        _ = loadTask(for: CacheKey(url: url, variant: variant))
    }

    private func loadTask(for key: CacheKey) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[key] { return existing }
        // Detached so the download + decode never inherit (and block) the MainActor
        // when kicked off from a card's `onAppear`/prefetch — decoding stays off the
        // main thread so the rail keeps scrolling smoothly.
        let task = Task<UIImage?, Never>.detached(priority: .utility) { [weak self] in
            guard let self else { return nil }
            defer { self.clearInFlight(key) }
            guard let data = await self.dataTask(for: key.url).value,
                  let image = Self.decodeImage(from: data, variant: key.variant) else {
                return nil
            }
            self.store(image, for: key)
            return image
        }
        inFlight[key] = task
        return task
    }

    private func dataTask(for url: URL) -> Task<Data?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = dataInFlight[url] { return existing }
        let task = Task<Data?, Never>.detached(priority: .utility) { [weak self] in
            defer { self?.clearDataInFlight(url) }
            return await Self.downloadData(url)
        }
        dataInFlight[url] = task
        return task
    }

    private func store(_ image: UIImage, for key: CacheKey) {
        let scale = image.scale
        let cost = Int(image.size.width * scale * image.size.height * scale * 4)
        cache.setObject(image, forKey: key.cacheKey, cost: max(cost, 1))
    }

    private func clearInFlight(_ key: CacheKey) {
        lock.lock()
        inFlight[key] = nil
        lock.unlock()
    }

    private func clearDataInFlight(_ url: URL) {
        lock.lock()
        dataInFlight[url] = nil
        lock.unlock()
    }

    private static func downloadData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        return data
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
