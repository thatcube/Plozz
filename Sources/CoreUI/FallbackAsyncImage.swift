#if canImport(SwiftUI)
import SwiftUI
import CoreModels
#if canImport(UIKit)
import UIKit
#endif

/// Loads the first artwork URL that succeeds from an ordered list of candidates,
/// advancing to the next whenever one fails (or is missing). When every
/// candidate is exhausted it renders the supplied placeholder.
///
/// Used by cards so an episode with no thumbnail can transparently fall back to
/// its series artwork, then to a neutral placeholder, with a single declaration.
///
/// When `maxAspectRatio` is set (width ÷ height), a candidate that loads but is
/// wider than that ratio is treated as unusable and skipped — this is how the
/// poster grid rejects "junk" provider art (a 16:9 episode still, or a
/// stills-grid composite Plex grabbed for an unmatched movie) and falls back to
/// the clean title placeholder instead of showing a wrong, wide image.
///
/// `content` decides how the resolved image is laid out, and defaults to the
/// crop-to-fill every card wants. A caller supplies its own when one image has
/// to be drawn more than once — Continue Watching draws the picture *and* a
/// mirrored continuation of it (see ``ExtendedArtworkFill``) — because taking
/// the resolved `Image` here keeps that to a single decode and a single resolve
/// task, where two `FallbackAsyncImage`s over the same URL would run two.
public struct FallbackAsyncImage<Content: View, Placeholder: View>: View {
    private let references: [ArtworkReference]
    private let maxAspectRatio: CGFloat?
    private let variant: ArtworkImageVariant
    private let previewVariant: ArtworkImageVariant?
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    private let onResolveReference: ((ArtworkReference?) -> Void)?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    public init(
        references: [ArtworkReference],
        maxAspectRatio: CGFloat? = nil,
        variant: ArtworkImageVariant = .original,
        previewVariant: ArtworkImageVariant? = nil,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        onResolveReference: ((ArtworkReference?) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.references = references
        self.maxAspectRatio = maxAspectRatio
        self.variant = variant
        self.previewVariant = previewVariant
        self.asyncFallbackURL = asyncFallbackURL
        self.onResolveReference = onResolveReference
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        #if canImport(UIKit)
        FilteredArtworkImage(
            references: references,
            maxAspectRatio: maxAspectRatio,
            variant: variant,
            previewVariant: previewVariant,
            asyncFallbackURL: asyncFallbackURL,
            onResolveReference: onResolveReference,
            content: content,
            placeholder: placeholder
        )
        #else
        SequentialAsyncImage(
            urls: references.compactMap {
                if case let .remote(url) = $0 { return url }
                return nil
            },
            content: content,
            placeholder: placeholder
        )
        #endif
    }
}

/// The layout every card wants for its artwork: resized to **fill** its slot,
/// cropping whatever overflows.
///
/// A named type rather than an inline closure because it is the default
/// `Content` of ``FallbackAsyncImage``, and a generic parameter can only be
/// defaulted by constraining it to something nameable.
public struct ArtworkFillImage: View {
    private let image: Image

    public init(_ image: Image) {
        self.image = image
    }

    public var body: some View {
        image
            .resizable()
            .aspectRatio(contentMode: .fill)
    }
}

extension FallbackAsyncImage where Content == ArtworkFillImage {
    public init(
        urls: [URL],
        maxAspectRatio: CGFloat? = nil,
        variant: ArtworkImageVariant = .original,
        previewVariant: ArtworkImageVariant? = nil,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            references: urls.map(ArtworkReference.remote),
            maxAspectRatio: maxAspectRatio,
            variant: variant,
            previewVariant: previewVariant,
            asyncFallbackURL: asyncFallbackURL,
            onResolveReference: nil,
            content: ArtworkFillImage.init,
            placeholder: placeholder
        )
    }

    public init(
        references: [ArtworkReference],
        maxAspectRatio: CGFloat? = nil,
        variant: ArtworkImageVariant = .original,
        previewVariant: ArtworkImageVariant? = nil,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            references: references,
            maxAspectRatio: maxAspectRatio,
            variant: variant,
            previewVariant: previewVariant,
            asyncFallbackURL: asyncFallbackURL,
            onResolveReference: nil,
            content: ArtworkFillImage.init,
            placeholder: placeholder
        )
    }
}

/// AsyncImage-based ordered fallback with no aspect filtering. Used wherever no
/// aspect guard is required (e.g. landscape/backdrop art).
private struct SequentialAsyncImage<Content: View, Placeholder: View>: View {
    let urls: [URL]
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var index = 0
    @Environment(\.themePalette) private var palette

    var body: some View {
        if index < urls.count {
            AsyncImage(url: urls[index]) { phase in
                switch phase {
                case let .success(image):
                    content(image)
                case .empty:
                    palette.fill
                case .failure:
                    Color.clear.onAppear(perform: advance)
                @unknown default:
                    Color.clear.onAppear(perform: advance)
                }
            }
            .id(index)
        } else {
            placeholder()
        }
    }

    private func advance() {
        if index < urls.count { index += 1 }
    }
}

#if canImport(UIKit)
/// Loads candidates in order, decoding each to inspect its true pixel aspect
/// ratio, and shows the first one that is poster-shaped enough (≤ `maxAspectRatio`).
/// Anything wider is skipped. Falls back to the placeholder when none qualify.
///
/// Decoded results live in `ArtworkImageCache`, so a card scrolled back into view
/// (or one whose art was prefetched ahead of scroll) seeds its image
/// synchronously and renders with no gray placeholder frame.
private struct FilteredArtworkImage<Content: View, Placeholder: View>: View {
    let references: [ArtworkReference]
    let maxAspectRatio: CGFloat?
    let variant: ArtworkImageVariant
    /// A cheaper variant to show FIRST while `variant` is still decoding.
    ///
    /// A detail hero asks for a 2000px backdrop; nothing has warmed it, because
    /// the row that was just scrolled warms each card's own poster at a different
    /// size entirely. So the page opened onto a scrim and waited on a cold fetch
    /// plus a full-size decode. Loading a 768px pass first puts a real image up
    /// roughly seven times sooner (by pixel count) and the full one replaces it in
    /// place — the same progressive ladder Home's hero already uses, which is why
    /// that one feels instant.
    ///
    /// `nil` keeps the single-pass behaviour every card uses: a poster is already
    /// small, and a second decode there would cost more than it saves.
    let previewVariant: ArtworkImageVariant?
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    /// Reports which candidate actually won, so a caller can react to WHICH art it
    /// got and not merely that it got some. `nil` when the async fallback supplied
    /// it, which is outside the ordered list.
    let onResolveReference: ((ArtworkReference?) -> Void)?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var resolved: Bool
    /// Whether `image` is the cheap pass, and so still owes a full-quality swap.
    @State private var isPreviewQuality = false
    @Environment(\.themePalette) private var palette
    /// The `.task` id the current `image`/`resolved` state was produced for. Lets
    /// `resolve()` tell "same inputs, keep the result" apart from "the urls
    /// changed (e.g. the player advanced to a new track), re-resolve" — the view
    /// keeps a stable identity in the full-screen player, so its `@State` survives
    /// across track changes and must be refreshed when the artwork url changes.
    @State private var loadedKey: String?

    init(
        references: [ArtworkReference],
        maxAspectRatio: CGFloat?,
        variant: ArtworkImageVariant,
        previewVariant: ArtworkImageVariant? = nil,
        asyncFallbackURL: (@Sendable () async -> URL?)?,
        onResolveReference: ((ArtworkReference?) -> Void)? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.references = references
        self.maxAspectRatio = maxAspectRatio
        self.variant = variant
        self.previewVariant = previewVariant
        self.asyncFallbackURL = asyncFallbackURL
        self.onResolveReference = onResolveReference
        self.content = content
        self.placeholder = placeholder
        // Seed synchronously from the decoded-image cache so an already-warmed card
        // renders its art on the very first frame — no async hop, no gray flash.
        let seeded = Self.cachedUsableImage(
            references: references,
            maxAspectRatio: maxAspectRatio,
            variant: variant,
            stopAtPrimary: true
        )
        let seededPreview = seeded == nil ? previewVariant.flatMap {
            Self.cachedUsableImage(references: references, maxAspectRatio: maxAspectRatio, variant: $0)
        } : nil
        _image = State(initialValue: (seeded ?? seededPreview)?.image)
        _resolved = State(initialValue: seeded != nil || seededPreview != nil)
        _isPreviewQuality = State(initialValue: seeded == nil && seededPreview != nil)
        _loadedKey = State(initialValue: seeded?.index == references.startIndex
            ? Self.makeKey(references: references, variant: variant, maxAspectRatio: maxAspectRatio)
            : nil)
    }

    private var taskKey: String {
        Self.makeKey(references: references, variant: variant, maxAspectRatio: maxAspectRatio)
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else if resolved {
                placeholder()
            } else {
                palette.fill
            }
        }
        .task(id: taskKey) {
            await resolve()
        }
    }

    private func resolve() async {
        let key = taskKey
        // Same inputs we already resolved for — keep the current result rather
        // than wiping it back to gray and re-resolving.
        if loadedKey == key, image != nil, !isPreviewQuality { return }
        // The urls changed (or this is the first run). Prefer a synchronous cache
        // hit for the *new* urls so a warmed image shows with no flash.
        let seeded = Self.cachedUsableImage(
            references: references,
            maxAspectRatio: maxAspectRatio,
            variant: variant,
            stopAtPrimary: true
        )
        if let seeded {
            image = seeded.image
            resolved = true
            isPreviewQuality = false
            onResolveReference?(references.indices.contains(seeded.index) ? references[seeded.index] : nil)
            if seeded.index == references.startIndex {
                loadedKey = key
                return
            }
        }
        // No cached image for the new inputs: drop any stale art so we never leave
        // a previous track's cover on screen, and show the loading state instead.
        if seeded == nil, !isPreviewQuality {
            image = nil
            resolved = false
        }
        // Progressive first pass. Deliberately before the full loop below, and
        // deliberately only when there is nothing on screen: an image already up is
        // never replaced by a cheaper one, so this can only ever fill a gap.
        if image == nil, let previewVariant {
            for reference in references {
                guard let loaded = await ArtworkImageCache.shared.image(
                    for: reference, variant: previewVariant
                ) else { continue }
                guard Self.usableSize(loaded, maxAspectRatio: maxAspectRatio) != nil else { continue }
                guard !Task.isCancelled else { return }
                image = loaded
                resolved = true
                isPreviewQuality = true
                break
            }
        }
        // Attempt the network passes more than once. A `nil` from the cache means
        // only "no image came back" — it does NOT distinguish "this title has no
        // artwork" from a transient miss (the load was cancelled while the list
        // settled, the account's artwork was momentarily not admitted during a
        // credential purge, or the request simply failed). Recording a transient
        // miss as final is what left visible cards blank until they were scrolled
        // off and back, which recycled the cell and retried by accident.
        for attempt in 0..<ArtworkResolveRetry.maxAttempts {
            // 1) Try provider candidates in order, skipping any that are too wide.
            for reference in references {
                guard let loaded = await ArtworkImageCache.shared.image(for: reference, variant: variant) else { continue }
                guard Self.usableSize(loaded, maxAspectRatio: maxAspectRatio) != nil else { continue }
                image = loaded
                resolved = true
                isPreviewQuality = false
                loadedKey = key
                onResolveReference?(reference)
                return
            }
            // 2) Nothing usable from the provider — try the async fallback (TMDb).
            if let asyncFallbackURL,
               let url = await asyncFallbackURL(),
               let loaded = await ArtworkImageCache.shared.image(for: url, variant: variant) {
                image = loaded
                resolved = true
                isPreviewQuality = false
                loadedKey = key
                onResolveReference?(nil)
                return
            }
            // Cancelled (the cell scrolled away, or the inputs changed): leave
            // `loadedKey` unset so the next run re-resolves from scratch instead
            // of inheriting this incomplete attempt as a final answer.
            if Task.isCancelled { return }
            if attempt < ArtworkResolveRetry.maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: ArtworkResolveRetry.delayNanoseconds)
                if Task.isCancelled { return }
            }
        }
        // Genuinely nothing to show after retrying: record it so we stop asking.
        resolved = true
        loadedKey = key
    }



    /// Stable key for a given set of inputs, used both as the `.task` id and to
    /// remember which inputs the current `image` was resolved for.
    private static func makeKey(references: [ArtworkReference], variant: ArtworkImageVariant, maxAspectRatio: CGFloat?) -> String {
        ([variant.rawValue, maxAspectRatio.map { "\($0)" } ?? "nil"] + references.map(\.privacySafeIdentity))
            .joined(separator: "\n")
    }

    /// First already-decoded candidate (in priority order) that is acceptable for
    /// this context, read synchronously from `ArtworkImageCache`.
    /// The best already-decoded image for these references.
    ///
    /// `stopAtPrimary` restricts the scan to the FIRST candidate, which is what
    /// synchronous seeding wants. Seeding used to scan the whole list and take
    /// whichever image happened to be resident, so a card whose primary poster
    /// wasn't cached yet — but whose local fallback art was — painted the fallback
    /// and then visibly swapped to the real poster a moment later. Measured while
    /// scrolling an NFS library: 742 cards in one pass, every one of them seeding
    /// from candidate 1 of 2.
    ///
    /// A lower-priority image is a reasonable thing to show on a BLANK card, and
    /// still is — the resolve loop below reaches it. It is not a reasonable thing
    /// to show when the right image is one decode away, because the viewer sees
    /// the correction rather than the answer.
    private static func cachedUsableImage(
        references: [ArtworkReference],
        maxAspectRatio: CGFloat?,
        variant: ArtworkImageVariant,
        stopAtPrimary: Bool = false
    ) -> (image: UIImage, index: Int)? {
        for (index, reference) in references.enumerated() {
            if stopAtPrimary, index > references.startIndex { return nil }
            guard let cached = ArtworkImageCache.shared.cachedImage(for: reference, variant: variant) else {
                if stopAtPrimary { return nil }
                continue
            }
            if usableSize(cached, maxAspectRatio: maxAspectRatio) != nil {
                return (cached, index)
            }
            if stopAtPrimary { return nil }
        }
        return nil
    }

    /// Returns the image's size when it is acceptable for this context, or `nil`
    /// when it should be skipped (wider than `maxAspectRatio`).
    private static func usableSize(_ image: UIImage, maxAspectRatio: CGFloat?) -> CGSize? {
        let size = image.size
        guard size.height > 0 else { return nil }
        if let maxAspectRatio, size.width / size.height > maxAspectRatio { return nil }
        return size
    }
}
#endif
#endif

/// Retry budget for ``FallbackAsyncImage``'s network passes. A file-level enum
/// because `FallbackAsyncImage` is generic, and generic types can't hold static
/// stored properties.
private enum ArtworkResolveRetry {
    /// One immediate pass plus two retries. Bounded on purpose: the retries only
    /// cost anything for artwork that is actually missing, and the task is
    /// cancelled the moment the cell leaves the screen.
    static let maxAttempts = 3
    /// Long enough for a warming session / in-flight purge to settle, short
    /// enough that a card fills in without the viewer noticing a second pass.
    static let delayNanoseconds: UInt64 = 400_000_000
}
