#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The Home **hero** backdrop, redesigned to take the image transition entirely
/// out of SwiftUI.
///
/// Every prior version animated the backdrop *within* SwiftUI — two opacity
/// layers, a `.transition`, or a single-offset filmstrip. All of them were prone
/// to the same intermittent, wrong-order artifact (the outgoing image lingering
/// while the incoming one animated in behind it, popped on top, then the old one
/// slid out) because SwiftUI's diffing/animation engine is free to decompose a
/// conceptually-single crossfade into two independently-animated, wrongly-ordered
/// views — especially under rapid paging or an interrupted animation.
///
/// This version sidesteps that class of bug completely: the image lives in a
/// single `UIImageView` and the transition is an **imperative Core Animation
/// cross-dissolve** (`UIView.transition(with:…, .transitionCrossDissolve)`).
/// There is exactly one view, so there is no z-order to get wrong and nothing to
/// linger; Core Animation snapshots the old contents and dissolves to the new in
/// one atomic step, and `.beginFromCurrentState` blends cleanly when a new page
/// interrupts an in-flight dissolve. SwiftUI only owns the *static* treatment —
/// the legibility scrim, the bottom dissolve mask, the overscan breakout and the
/// scroll parallax — none of which change between slides, so none of it animates.
struct HomeHeroBackdrop: View {
    /// Ordered candidate backdrop URLs for the **currently fronted** slide (first
    /// that loads and is wide-enough wins). Changing this is what drives a
    /// crossfade to the new slide's art.
    let urls: [URL]
    /// Last-resort async art lookup (e.g. TMDb) when none of `urls` load.
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let width: CGFloat
    let height: CGFloat
    /// Legibility scrim tone — dark in dark mode, light in light mode.
    let scrimTone: Color
    /// Fraction of the height at which the bottom dissolve begins.
    let dissolveStart: CGFloat
    /// Parallax lift (points) applied as the page scrolls toward Continue Watching.
    let parallaxLift: CGFloat

    var body: some View {
        backdropImage
            .frame(width: width, height: height)
            .clipped()
            .overlay(scrim)
            .mask(dissolveMask)
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(y: -parallaxLift)
            .ignoresSafeArea(edges: [.top, .horizontal])
    }

    @ViewBuilder
    private var backdropImage: some View {
        #if canImport(UIKit)
        CrossfadeImageView(urls: urls, asyncFallbackURL: asyncFallbackURL)
        #else
        Rectangle().fill(.tertiary)
        #endif
    }

    /// Legibility scrim — identical to `HeroBackdropLayer`'s. It lives under the
    /// dissolve mask so it fades away with the image and never tints the revealed
    /// background. Static across slides, so it never animates.
    private var scrim: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.20),
                .init(color: scrimTone.opacity(0.72), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0.0),
                    .init(color: .white, location: 0.40),
                    .init(color: .clear, location: 0.85)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    /// Bottom dissolve mask — identical to `HeroBackdropLayer`'s. Static across
    /// slides.
    private var dissolveMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.0),
                .init(color: .white, location: dissolveStart),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#if canImport(UIKit)
/// A single `UIImageView` that imperatively cross-dissolves between backdrop
/// images. This is the whole point of the redesign: the transition is Core
/// Animation, not SwiftUI, so it is deterministic and can never split into two
/// wrongly-ordered layers.
///
/// Loading is cache-first (synchronous when the image is already decoded — which
/// it usually is, because `HomeHeroView` prefetches the current slide and its two
/// neighbours), otherwise it loads asynchronously and dissolves once ready. Every
/// load is guarded by a monotonic token so a slow load for a slide the user has
/// already paged past can never win, and crossfades are serialized so a burst of
/// rapid pages settles cleanly on the final slide's art.
private struct CrossfadeImageView: UIViewRepresentable {
    let urls: [URL]
    let asyncFallbackURL: (@Sendable () async -> URL?)?

    /// Backdrops are landscape; anything wider than 3:1 is junk provider art and
    /// is skipped (matches `HeroBackdropLayer`'s `maxAspectRatio`).
    private static let maxAspectRatio: CGFloat = 3.0
    private static let crossfadeDuration: TimeInterval = 0.5

    func makeCoordinator() -> Coordinator {
        Coordinator(maxAspectRatio: Self.maxAspectRatio, crossfadeDuration: Self.crossfadeDuration)
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.imageView = imageView
        // First image is placed with no animation.
        context.coordinator.update(urls: urls, asyncFallbackURL: asyncFallbackURL, animated: false)
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.imageView = uiView
        context.coordinator.update(urls: urls, asyncFallbackURL: asyncFallbackURL, animated: true)
    }

    @MainActor
    final class Coordinator {
        weak var imageView: UIImageView?
        private let maxAspectRatio: CGFloat
        private let crossfadeDuration: TimeInterval

        /// Key of the art currently shown on screen.
        private var displayedKey: String?
        /// Key of the latest requested art (may still be loading).
        private var targetKey: String?
        /// Monotonic token; only the newest load may apply its result.
        private var loadToken = 0
        private var isTransitioning = false
        /// A newer target that arrived mid-dissolve, applied on completion.
        private var pendingImage: UIImage?
        private var pendingKey: String?

        init(maxAspectRatio: CGFloat, crossfadeDuration: TimeInterval) {
            self.maxAspectRatio = maxAspectRatio
            self.crossfadeDuration = crossfadeDuration
        }

        func update(urls: [URL], asyncFallbackURL: (@Sendable () async -> URL?)?, animated: Bool) {
            let key = Self.key(for: urls)
            // Already showing or already targeting this art — nothing to do. This
            // makes the countless non-URL SwiftUI updates (scroll, focus, etc.)
            // free, and prevents a redundant crossfade.
            guard key != targetKey else { return }
            targetKey = key
            loadToken += 1
            let token = loadToken

            // Synchronous cache hit (the common case — neighbours are prefetched):
            // dissolve immediately with no async hop.
            if let cached = firstUsableCached(urls) {
                apply(cached, key: key, animated: animated)
                return
            }

            // Not decoded yet: load then dissolve once ready, if still the target.
            Task { [weak self] in
                guard let self else { return }
                let image = await self.firstUsableLoaded(urls, asyncFallbackURL: asyncFallbackURL)
                guard token == self.loadToken else { return } // superseded by a newer page
                self.apply(image, key: key, animated: animated)
            }
        }

        private func apply(_ image: UIImage?, key: String, animated: Bool) {
            guard let imageView, key == targetKey else { return }
            guard let image else {
                // No art resolved for this slide; keep whatever is shown rather than
                // flashing to empty. Mark as displayed so we don't retry endlessly.
                displayedKey = key
                return
            }
            let firstPaint = displayedKey == nil || imageView.image == nil
            guard animated && !firstPaint else {
                imageView.image = image
                displayedKey = key
                return
            }
            if isTransitioning {
                // Fold into the in-flight dissolve; apply on its completion.
                pendingImage = image
                pendingKey = key
                return
            }
            crossfade(to: image, key: key)
        }

        private func crossfade(to image: UIImage, key: String) {
            guard let imageView else { return }
            isTransitioning = true
            UIView.transition(
                with: imageView,
                duration: crossfadeDuration,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
            ) {
                imageView.image = image
            } completion: { [weak self] _ in
                guard let self else { return }
                self.displayedKey = key
                self.isTransitioning = false
                // A newer target arrived mid-dissolve — dissolve on to it now.
                if let pendingKey = self.pendingKey, let pendingImage = self.pendingImage,
                   pendingKey == self.targetKey, pendingKey != self.displayedKey {
                    self.pendingKey = nil
                    self.pendingImage = nil
                    self.crossfade(to: pendingImage, key: pendingKey)
                } else {
                    self.pendingKey = nil
                    self.pendingImage = nil
                }
            }
        }

        // MARK: - Loading

        private func firstUsableCached(_ urls: [URL]) -> UIImage? {
            for url in urls {
                guard let cached = ArtworkImageCache.shared.cachedImage(for: url) else { continue }
                if isUsable(cached) { return cached }
            }
            return nil
        }

        private func firstUsableLoaded(
            _ urls: [URL],
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) async -> UIImage? {
            for url in urls {
                guard let loaded = await ArtworkImageCache.shared.image(for: url) else { continue }
                if isUsable(loaded) { return loaded }
            }
            if let asyncFallbackURL, let url = await asyncFallbackURL(),
               let loaded = await ArtworkImageCache.shared.image(for: url), isUsable(loaded) {
                return loaded
            }
            return nil
        }

        private func isUsable(_ image: UIImage) -> Bool {
            let size = image.size
            guard size.height > 0 else { return false }
            return size.width / size.height <= maxAspectRatio
        }

        private static func key(for urls: [URL]) -> String {
            urls.map(\.absoluteString).joined(separator: "|")
        }
    }
}
#endif
#endif
