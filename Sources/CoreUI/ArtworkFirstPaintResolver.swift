#if canImport(UIKit)
import CoreModels
import Foundation
import MetadataKit
import UIKit

/// One decoded artwork identity selected before first paint.
public struct FirstPaintArtwork: @unchecked Sendable {
    public let image: UIImage
    public let reference: ArtworkReference
    public let variant: ArtworkImageVariant

    public init(
        image: UIImage,
        reference: ArtworkReference,
        variant: ArtworkImageVariant
    ) {
        self.image = image
        self.reference = reference
        self.variant = variant
    }
}

/// Selects online-versus-library artwork without ever publishing a provisional
/// image. A timed-out online task keeps running to warm shared caches, but its
/// result is not returned after a library image wins this appearance.
public enum ArtworkFirstPaintResolver {
    public static let denseArtworkWait: TimeInterval = 0.5
    public static let focalArtworkWait: TimeInterval = 2

    public static func resolve(
        references: [ArtworkReference],
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat? = nil,
        asyncOnlineURL: (@Sendable () async -> URL?)?,
        maximumOnlineWait: TimeInterval,
        prefersOnlineArtwork: Bool? = nil,
        sharedKey: String? = nil
    ) async -> FirstPaintArtwork? {
        if let sharedKey {
            return await FirstPaintTaskMemo.shared.value(for: sharedKey) {
                await resolve(
                    references: references,
                    variant: variant,
                    maxAspectRatio: maxAspectRatio,
                    asyncOnlineURL: asyncOnlineURL,
                    maximumOnlineWait: maximumOnlineWait,
                    prefersOnlineArtwork: prefersOnlineArtwork,
                    sharedKey: nil
                )
            }
        }
        let prefersOnline = prefersOnlineArtwork
            ?? MetadataProviderSettingsStore().load().preferOnlineArtwork

        guard prefersOnline, let asyncOnlineURL else {
            if let local = await loadFirst(
                references,
                variant: variant,
                maxAspectRatio: maxAspectRatio
            ) {
                return local
            }
            return await loadOnline(
                asyncOnlineURL,
                variant: variant,
                maxAspectRatio: maxAspectRatio
            )
        }

        let onlineTask = Task {
            await loadOnline(
                asyncOnlineURL,
                variant: variant,
                maxAspectRatio: maxAspectRatio
            )
        }
        let race = FirstPaintRace()
        Task {
            await race.submit(.resolved(await onlineTask.value))
        }
        Task {
            let nanoseconds = UInt64(max(0, maximumOnlineWait) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await race.submit(.timedOut)
        }

        let outcome = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            Task { await race.submit(.cancelled) }
        }
        switch outcome {
        case .resolved(let artwork):
            if let artwork { return artwork }
        case .timedOut:
            break
        case .cancelled:
            return nil
        }

        if let local = await loadFirst(
            references,
            variant: variant,
            maxAspectRatio: maxAspectRatio
        ) {
            return local
        }
        guard !Task.isCancelled else { return nil }
        return await onlineTask.value
    }

    private static func loadFirst(
        _ references: [ArtworkReference],
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat?
    ) async -> FirstPaintArtwork? {
        for reference in references {
            guard !Task.isCancelled else { return nil }
            guard let image = await ArtworkImageCache.shared.image(
                for: reference,
                variant: variant
            ), isUsable(image, maxAspectRatio: maxAspectRatio) else {
                continue
            }
            return FirstPaintArtwork(
                image: image,
                reference: reference,
                variant: variant
            )
        }
        return nil
    }

    private static func loadOnline(
        _ resolver: (@Sendable () async -> URL?)?,
        variant: ArtworkImageVariant,
        maxAspectRatio: CGFloat?
    ) async -> FirstPaintArtwork? {
        guard !Task.isCancelled,
              let resolver,
              let url = await resolver(),
              !Task.isCancelled,
              let image = await ArtworkImageCache.shared.image(
                  for: url,
                  variant: variant
              ),
              isUsable(image, maxAspectRatio: maxAspectRatio) else {
            return nil
        }
        return FirstPaintArtwork(
            image: image,
            reference: .remote(url),
            variant: variant
        )
    }

    private static func isUsable(
        _ image: UIImage,
        maxAspectRatio: CGFloat?
    ) -> Bool {
        guard image.size.height > 0 else { return false }
        guard let maxAspectRatio else { return true }
        return image.size.width / image.size.height <= maxAspectRatio
    }
}

private enum FirstPaintRaceResult: @unchecked Sendable {
    case resolved(FirstPaintArtwork?)
    case timedOut
    case cancelled
}

private actor FirstPaintRace {
    private var result: FirstPaintRaceResult?
    private var continuation: CheckedContinuation<FirstPaintRaceResult, Never>?

    func submit(_ candidate: FirstPaintRaceResult) {
        guard result == nil else { return }
        result = candidate
        continuation?.resume(returning: candidate)
        continuation = nil
    }

    func value() async -> FirstPaintRaceResult {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}

private actor FirstPaintTaskMemo {
    static let shared = FirstPaintTaskMemo()

    private var tasks: [String: Task<FirstPaintArtwork?, Never>] = [:]
    private var order: [String] = []
    private let capacity = 300

    func value(
        for key: String,
        operation: @escaping @Sendable () async -> FirstPaintArtwork?
    ) async -> FirstPaintArtwork? {
        if let task = tasks[key] {
            return await task.value
        }
        let task = Task(operation: operation)
        tasks[key] = task
        order.append(key)
        if order.count > capacity {
            let oldest = order.removeFirst()
            tasks[oldest] = nil
        }
        return await task.value
    }
}
#endif
