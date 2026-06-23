#if canImport(UIKit)
import UIKit
import CoreModels

/// Loads, parses, and slices a Plex **BIF** trickplay blob into single scrubbing
/// thumbnails.
///
/// Unlike Jellyfin (a handful of tile-grid images), Plex packs every preview
/// frame into one BIF file. So this loader downloads that blob **once**, lazily
/// on the first scrub, parses its index, then slices + decodes individual JPEG
/// frames on demand — keeping a small LRU of decoded frames so dragging within a
/// frame's interval is an instant in-memory hit. Concurrent first requests
/// coalesce onto the single download.
@MainActor
final class PlexBIFThumbnailLoader: ScrubThumbnailProviding {
    private let url: URL
    private let session: URLSession

    private var blob: Data?
    private var index: BIFIndex?
    private var loadTask: Task<Bool, Never>?
    private var loadFailed = false

    /// Decoded-frame cache keyed by frame index, with FIFO eviction to bound
    /// memory (decoded SD frames are small, but a long movie has many).
    private var decoded: [Int: CGImage] = [:]
    private var decodeOrder: [Int] = []
    private let maxDecodedFrames = 90

    init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    func thumbnail(forSeconds seconds: TimeInterval) async -> CGImage? {
        if index == nil, !loadFailed {
            _ = await ensureLoaded()
        }
        return decode(forSeconds: seconds)
    }

    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        // Once the blob is in memory, decoding a single small JPEG is cheap
        // enough to do synchronously, so previews stay instant across frames.
        decode(forSeconds: seconds)
    }

    /// Returns the frame for a position, decoding (and caching) it if the blob is
    /// loaded; `nil` if the blob isn't available yet or the frame can't resolve.
    private func decode(forSeconds seconds: TimeInterval) -> CGImage? {
        guard let index, let blob, let frameIndex = index.frameIndex(forSeconds: seconds) else {
            return nil
        }
        if let cached = decoded[frameIndex] { return cached }
        let frame = index.frames[frameIndex]
        guard frame.offset >= 0, frame.length > 0, frame.offset + frame.length <= blob.count else {
            return nil
        }
        let jpeg = blob.subdata(in: frame.range)
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        store(image, at: frameIndex)
        return image
    }

    private func store(_ image: CGImage, at frameIndex: Int) {
        decoded[frameIndex] = image
        decodeOrder.append(frameIndex)
        if decodeOrder.count > maxDecodedFrames {
            let evicted = decodeOrder.removeFirst()
            // Only drop it if a later insert hasn't refreshed the same key.
            if !decodeOrder.contains(evicted) { decoded[evicted] = nil }
        }
    }

    /// Downloads + parses the BIF blob exactly once, coalescing concurrent calls.
    private func ensureLoaded() async -> Bool {
        if index != nil { return true }
        if loadFailed { return false }
        if let existing = loadTask { return await existing.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            guard let (data, _) = try? await self.session.data(from: self.url),
                  let parsed = BIFIndex(data: data) else {
                self.loadFailed = true
                return false
            }
            self.blob = data
            self.index = parsed
            return true
        }
        loadTask = task
        let ok = await task.value
        loadTask = nil
        return ok
    }
}
#endif
