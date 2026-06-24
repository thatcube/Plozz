#if canImport(UIKit)
import UIKit
import CoreModels
import CoreNetworking

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
        if index == nil {
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
            PlozzLog.playback.debug("Plex BIF frame out of bounds index=\(frameIndex)")
            return nil
        }
        let jpeg = blob.subdata(in: frame.range)
        guard let image = UIImage(data: jpeg)?.cgImage else {
            PlozzLog.playback.debug("Plex BIF frame decode failed index=\(frameIndex)")
            return nil
        }
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

    /// Downloads + parses the BIF blob, coalescing concurrent calls and retrying
    /// later attempts after a failure.
    private func ensureLoaded() async -> Bool {
        if index != nil { return true }
        if let existing = loadTask { return await existing.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            do {
                let (data, response) = try await self.session.data(from: self.url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    PlozzLog.playback.debug(
                        "Plex BIF request failed status=\(http.statusCode) url=\(PlozzLog.redact(url: self.url))"
                    )
                    return false
                }
                guard let parsed = BIFIndex(data: data) else {
                    PlozzLog.playback.debug(
                        "Plex BIF parse failed url=\(PlozzLog.redact(url: self.url)) size=\(data.count)"
                    )
                    return false
                }
                self.blob = data
                self.index = parsed
                self.decoded.removeAll(keepingCapacity: true)
                self.decodeOrder.removeAll(keepingCapacity: true)
                return true
            } catch {
                PlozzLog.playback.debug(
                    "Plex BIF request error=\(String(reflecting: error)) url=\(PlozzLog.redact(url: self.url))"
                )
                return false
            }
        }
        loadTask = task
        let ok = await task.value
        loadTask = nil
        return ok
    }
}
#endif
