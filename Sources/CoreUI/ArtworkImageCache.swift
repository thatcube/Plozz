#if canImport(UIKit)
import UIKit

/// Process-wide, in-memory cache of *decoded* artwork images, keyed by source URL.
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

    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    /// In-flight loads keyed by URL, so a card's own load and the rail's prefetch
    /// never fetch + decode the same artwork twice.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        // Decoded landscape/poster thumbnails are small; cap retained pixels so the
        // cache stays bounded on long seasons (NSCache evicts under memory pressure
        // regardless).
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// The decoded image for `url` if one is already resident, read synchronously.
    public func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Returns the decoded image for `url`, serving a cached copy immediately when
    /// present and otherwise downloading + decoding it once (coalescing concurrent
    /// callers). Result is stored for synchronous reuse via `cachedImage(for:)`.
    @discardableResult
    public func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        let task = loadTask(for: url)
        return await task.value
    }

    /// Warms the cache for `url` without awaiting the result — fire-and-forget
    /// prefetch used by rails to decode upcoming cards ahead of scroll.
    public func prefetch(_ url: URL) {
        guard cachedImage(for: url) == nil else { return }
        _ = loadTask(for: url)
    }

    private func loadTask(for url: URL) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[url] { return existing }
        // Detached so the download + decode never inherit (and block) the MainActor
        // when kicked off from a card's `onAppear`/prefetch — decoding stays off the
        // main thread so the rail keeps scrolling smoothly.
        let task = Task<UIImage?, Never>.detached(priority: .utility) { [weak self] in
            let image = await Self.download(url)
            if let self, let image { self.store(image, for: url) }
            self?.clearInFlight(url)
            return image
        }
        inFlight[url] = task
        return task
    }

    private func store(_ image: UIImage, for url: URL) {
        let scale = image.scale
        let cost = Int(image.size.width * scale * image.size.height * scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: max(cost, 1))
    }

    private func clearInFlight(_ url: URL) {
        lock.lock()
        inFlight[url] = nil
        lock.unlock()
    }

    private static func download(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
        guard let image = UIImage(data: data) else { return nil }
        // Force-decode now (off the main thread) so the cached image is render-ready.
        return image.preparingForDisplay() ?? image
    }
}
#endif
