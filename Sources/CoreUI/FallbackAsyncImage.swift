#if canImport(SwiftUI)
import SwiftUI
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
public struct FallbackAsyncImage<Placeholder: View>: View {
    private let urls: [URL]
    private let maxAspectRatio: CGFloat?
    private let variant: ArtworkImageVariant
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    private let placeholder: () -> Placeholder

    public init(
        urls: [URL],
        maxAspectRatio: CGFloat? = nil,
        variant: ArtworkImageVariant = .original,
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.maxAspectRatio = maxAspectRatio
        self.variant = variant
        self.asyncFallbackURL = asyncFallbackURL
        self.placeholder = placeholder
    }

    public var body: some View {
        #if canImport(UIKit)
        if maxAspectRatio != nil || asyncFallbackURL != nil || variant != .original {
            FilteredArtworkImage(
                urls: urls,
                maxAspectRatio: maxAspectRatio,
                variant: variant,
                asyncFallbackURL: asyncFallbackURL,
                placeholder: placeholder
            )
        } else {
            SequentialAsyncImage(urls: urls, placeholder: placeholder)
        }
        #else
        SequentialAsyncImage(urls: urls, placeholder: placeholder)
        #endif
    }
}

/// AsyncImage-based ordered fallback with no aspect filtering. Used wherever no
/// aspect guard is required (e.g. landscape/backdrop art).
private struct SequentialAsyncImage<Placeholder: View>: View {
    let urls: [URL]
    let placeholder: () -> Placeholder

    @State private var index = 0

    var body: some View {
        if index < urls.count {
            AsyncImage(url: urls[index]) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .empty:
                    Color.primary.opacity(0.06)
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
private struct FilteredArtworkImage<Placeholder: View>: View {
    let urls: [URL]
    let maxAspectRatio: CGFloat?
    let variant: ArtworkImageVariant
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var resolved: Bool
    /// The `.task` id the current `image`/`resolved` state was produced for. Lets
    /// `resolve()` tell "same inputs, keep the result" apart from "the urls
    /// changed (e.g. the player advanced to a new track), re-resolve" — the view
    /// keeps a stable identity in the full-screen player, so its `@State` survives
    /// across track changes and must be refreshed when the artwork url changes.
    @State private var loadedKey: String?

    init(
        urls: [URL],
        maxAspectRatio: CGFloat?,
        variant: ArtworkImageVariant,
        asyncFallbackURL: (@Sendable () async -> URL?)?,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.urls = urls
        self.maxAspectRatio = maxAspectRatio
        self.variant = variant
        self.asyncFallbackURL = asyncFallbackURL
        self.placeholder = placeholder
        // Seed synchronously from the decoded-image cache so an already-warmed card
        // renders its art on the very first frame — no async hop, no gray flash.
        let seeded = Self.cachedUsableImage(urls: urls, maxAspectRatio: maxAspectRatio, variant: variant)
        _image = State(initialValue: seeded)
        _resolved = State(initialValue: seeded != nil)
        _loadedKey = State(initialValue: seeded != nil
            ? Self.makeKey(urls: urls, variant: variant, maxAspectRatio: maxAspectRatio)
            : nil)
    }

    private var taskKey: String {
        Self.makeKey(urls: urls, variant: variant, maxAspectRatio: maxAspectRatio)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if resolved {
                placeholder()
            } else {
                Color.primary.opacity(0.06)
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
        if loadedKey == key, image != nil { return }
        // The urls changed (or this is the first run). Prefer a synchronous cache
        // hit for the *new* urls so a warmed image shows with no flash.
        if let seeded = Self.cachedUsableImage(urls: urls, maxAspectRatio: maxAspectRatio, variant: variant) {
            image = seeded
            resolved = true
            loadedKey = key
            return
        }
        // No cached image for the new inputs: drop any stale art so we never leave
        // a previous track's cover on screen, and show the loading state instead.
        image = nil
        resolved = false
        // 1) Try provider candidates in order, skipping any that are too wide.
        for url in urls {
            guard let loaded = await ArtworkImageCache.shared.image(for: url, variant: variant) else { continue }
            guard Self.usableSize(loaded, maxAspectRatio: maxAspectRatio) != nil else { continue }
            image = loaded
            resolved = true
            loadedKey = key
            return
        }
        // 2) Nothing usable from the provider — try the async fallback (TMDb).
        if let asyncFallbackURL,
           let url = await asyncFallbackURL(),
           let loaded = await ArtworkImageCache.shared.image(for: url, variant: variant) {
            image = loaded
            resolved = true
            loadedKey = key
            return
        }
        resolved = true
        loadedKey = key
    }

    /// Stable key for a given set of inputs, used both as the `.task` id and to
    /// remember which inputs the current `image` was resolved for.
    private static func makeKey(urls: [URL], variant: ArtworkImageVariant, maxAspectRatio: CGFloat?) -> String {
        ([variant.rawValue, maxAspectRatio.map { "\($0)" } ?? "nil"] + urls.map(\.absoluteString))
            .joined(separator: "\n")
    }

    /// First already-decoded candidate (in priority order) that is acceptable for
    /// this context, read synchronously from `ArtworkImageCache`.
    private static func cachedUsableImage(
        urls: [URL],
        maxAspectRatio: CGFloat?,
        variant: ArtworkImageVariant
    ) -> UIImage? {
        for url in urls {
            guard let cached = ArtworkImageCache.shared.cachedImage(for: url, variant: variant) else { continue }
            if usableSize(cached, maxAspectRatio: maxAspectRatio) != nil { return cached }
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
