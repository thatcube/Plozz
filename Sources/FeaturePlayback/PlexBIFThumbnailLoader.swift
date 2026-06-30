#if canImport(UIKit)
import UIKit
import CoreModels
import CoreNetworking

/// Box that carries an immutable, thread-safe `CGImage` across an actor boundary.
/// `CGImage` isn't statically `Sendable`, but a decoded image is read-only, so an
/// `@unchecked Sendable` wrapper is safe for handing an off-main decode back to
/// the main actor.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

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
        guard let frameIndex = index?.frameIndex(forSeconds: seconds) else { return nil }
        if let cached = decoded[frameIndex] { return cached }
        guard let jpeg = jpegData(atFrameIndex: frameIndex) else { return nil }
        // Decode off the main thread: a scrub gesture drives this from the main
        // runloop, and a synchronous JPEG decode per frame stalls the gesture
        // loop (the "scrubbing hangs" feel). The detached task keeps the decode
        // off-main; we store + return on the main actor.
        guard let image = await Self.decodeJPEG(jpeg) else { return nil }
        store(image, at: frameIndex)
        return image
    }

    func cachedThumbnail(forSeconds seconds: TimeInterval) -> CGImage? {
        // Memory-only fast path — NEVER decodes. Honors the protocol contract so
        // dragging stays fluid: a miss returns nil and the caller falls back to
        // the async `thumbnail` path (which decodes off-main). Decoding here would
        // block the gesture thread on every pan sample across fresh frames.
        guard let frameIndex = index?.frameIndex(forSeconds: seconds) else { return nil }
        return decoded[frameIndex]
    }

    func prefetch() {
        // Kick the (coalesced) blob download so the first scrub has data ready.
        Task { _ = await ensureLoaded() }
    }

    /// Slices the JPEG bytes for a frame out of the in-memory blob. Cheap (a
    /// `Data` subrange copy) and safe to run on the main actor; the expensive
    /// decode is done separately, off-main.
    private func jpegData(atFrameIndex frameIndex: Int) -> Data? {
        guard let index, let blob, index.frames.indices.contains(frameIndex) else { return nil }
        let frame = index.frames[frameIndex]
        guard frame.offset >= 0, frame.length > 0, frame.offset + frame.length <= blob.count else {
            PlozzLog.playback.debug("Plex BIF frame out of bounds index=\(frameIndex)")
            return nil
        }
        return blob.subdata(in: frame.range)
    }

    /// Decodes JPEG bytes into a `CGImage` on a background executor. `CGImage` is
    /// immutable and thread-safe but not statically `Sendable`, so it crosses back
    /// to the main actor inside an `@unchecked Sendable` box.
    private static func decodeJPEG(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> SendableCGImage? in
            guard let cgImage = UIImage(data: data)?.cgImage else { return nil }
            return SendableCGImage(cgImage)
        }.value?.image
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
