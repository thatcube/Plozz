#if canImport(SwiftUI)
import SwiftUI
import CoreUI
#if canImport(UIKit)
import UIKit
#endif

/// The Home **hero** backdrop, redesigned around the Apple TV app's "parallax
/// wipe" page transition.
///
/// ### Why this shape
/// Every SwiftUI-driven attempt at the wipe (two opacity layers, `.transition`,
/// a `.offset` filmstrip, `zIndex`) suffered the same intermittent wrong-order
/// artifact: SwiftUI is free to decompose one logical transition into two
/// independently-scheduled, wrongly-ordered animations — especially under rapid
/// paging or an interrupted animation. A UIKit cross-dissolve fixed the ordering
/// but is motionless and, per Brandon, "ugly."
///
/// This version keeps the winning idea — **the transition lives entirely in UIKit
/// / Core Animation; SwiftUI only hands it a target** — but replaces the dissolve
/// with the real Apple TV effect: a **two-layer horizontal push with content
/// parallax**. See ``HeroWipeContainerView``:
/// - two page layers with **explicit, fixed `zPosition`** (incoming always on top)
///   so the render order is deterministic and immune to SwiftUI/​layout churn;
/// - both pages slide the full slide width (old exits, new enters);
/// - the *image content within each page* moves at a slower rate (a clipped,
///   oversized inner image view translated via its own transform) so the incoming
///   art "settles" into place — the depth cue that makes it read as parallax.
///
/// SwiftUI owns only the STATIC treatment (legibility scrim, bottom dissolve mask,
/// overscan breakout, vertical scroll parallax) — none of which changes between
/// slides, so none of it animates.
struct HomeHeroBackdrop: View {
    /// Ordered candidate backdrop URLs for the **currently fronted** slide.
    let urls: [URL]
    /// Last-resort async art lookup (e.g. TMDb) when none of `urls` load.
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    /// Stable identity of the fronted slide (the item id). A *change* in this is
    /// what triggers a wipe — never a mere `urls` array rebuild for the same slide.
    let slideID: String
    /// Direction of the page that fronted `slideID`: `true` = forward (incoming
    /// enters from the trailing edge), `false` = backward (from the leading edge).
    let forward: Bool
    let width: CGFloat
    let height: CGFloat
    /// Legibility scrim tone — dark in dark mode, light in light mode.
    let scrimTone: Color
    /// Fraction of the height at which the bottom dissolve begins.
    let dissolveStart: CGFloat
    /// Vertical parallax lift (points) applied as the page scrolls toward Continue
    /// Watching. Applied in SwiftUI, outside the horizontal wipe.
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
        WipeImageView(
            urls: urls,
            asyncFallbackURL: asyncFallbackURL,
            slideID: slideID,
            forward: forward,
            width: width,
            height: height
        )
        #else
        Rectangle().fill(.tertiary)
        #endif
    }

    /// Legibility scrim — identical to `HeroBackdropLayer`'s. Lives under the
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
/// SwiftUI bridge for the parallax-wipe backdrop. The representable is *inert*:
/// it only forwards the fronted slide's identity/URLs/direction to the coordinator,
/// which owns the entire Core Animation transition. Because SwiftUI never animates
/// the image layers, it can never decompose the wipe into wrong-order pieces.
private struct WipeImageView: UIViewRepresentable {
    let urls: [URL]
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let slideID: String
    let forward: Bool
    let width: CGFloat
    let height: CGFloat

    /// Backdrops are landscape; anything wider than 3:1 is junk provider art and
    /// is skipped (matches `HeroBackdropLayer`'s `maxAspectRatio`).
    private static let maxAspectRatio: CGFloat = 3.0
    private static let duration: TimeInterval = 0.5
    /// Points the inner image "leads" its page by, then settles — the parallax
    /// depth cue. Also the horizontal bleed each image view is oversized by, so a
    /// parallax translation never reveals a blank edge.
    private static let parallaxBleed: CGFloat = 80

    func makeCoordinator() -> Coordinator {
        Coordinator(maxAspectRatio: Self.maxAspectRatio, duration: Self.duration)
    }

    func makeUIView(context: Context) -> HeroWipeContainerView {
        let view = HeroWipeContainerView(bleed: Self.parallaxBleed)
        context.coordinator.container = view
        context.coordinator.configure(width: width, height: height)
        context.coordinator.update(
            urls: urls, slideID: slideID, forward: forward, asyncFallbackURL: asyncFallbackURL
        )
        return view
    }

    func updateUIView(_ uiView: HeroWipeContainerView, context: Context) {
        context.coordinator.container = uiView
        context.coordinator.configure(width: width, height: height)
        context.coordinator.update(
            urls: urls, slideID: slideID, forward: forward, asyncFallbackURL: asyncFallbackURL
        )
    }

    // MARK: - Coordinator

    /// Owns transition scheduling: which slide is displayed, which is the pending
    /// target, cache-first art loading (with a monotonic token so only the newest
    /// target can apply), and serialization of the wipe so a burst of rapid pages
    /// coalesces to the newest target with one clean animation.
    @MainActor
    final class Coordinator {
        weak var container: HeroWipeContainerView?
        private let maxAspectRatio: CGFloat
        private let duration: TimeInterval

        /// Identity of the slide currently settled on screen.
        private var displayedID: String?
        /// URL of the art currently settled on screen (for same-slide upgrades).
        private var displayedURL: URL?
        /// Identity of the latest requested slide (may still be loading).
        private var targetID: String?
        /// Monotonic load token; only the newest requested art may apply.
        private var loadToken = 0
        private var isAnimating = false
        private var animator: UIViewPropertyAnimator?
        /// Newest fully-resolved target that arrived while a wipe was in flight,
        /// applied on completion. Always the most recent — never a queue.
        private var pending: (image: UIImage, url: URL, id: String, forward: Bool)?
        /// Newest target that resolved to *no* usable art while a wipe was in
        /// flight. Reconciled on completion so state can't get stuck pointing at a
        /// slide that never became `displayed` (and a later cached upgrade for it
        /// can still apply in place).
        private var pendingNoArtID: String?

        init(maxAspectRatio: CGFloat, duration: TimeInterval) {
            self.maxAspectRatio = maxAspectRatio
            self.duration = duration
        }

        func configure(width: CGFloat, height: CGFloat) {
            container?.slideSize = CGSize(width: width, height: height)
        }

        func update(
            urls: [URL],
            slideID: String,
            forward: Bool,
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) {
            // Same slide already shown/targeted: this is one of the countless
            // non-paging SwiftUI updates (scroll, focus, parallax). Free — except
            // we opportunistically upgrade the *displayed* slide's art if a better
            // (higher-res / router-resolved) candidate has since been cached.
            if slideID == targetID {
                maybeUpgradeDisplayedArt(urls: urls)
                return
            }
            targetID = slideID
            loadToken += 1
            let token = loadToken

            // Synchronous cache hit (the common case — neighbours are prefetched):
            // wipe immediately with no async hop.
            if let (image, url) = firstUsableCached(urls) {
                applyResolved(image, url: url, id: slideID, forward: forward)
                return
            }
            // Not decoded yet: load, then wipe once ready — if still the target.
            Task { [weak self] in
                guard let self else { return }
                let resolved = await self.firstUsableLoaded(urls, asyncFallbackURL: asyncFallbackURL)
                guard token == self.loadToken else { return } // superseded by a newer page
                if let (image, url) = resolved {
                    self.applyResolved(image, url: url, id: slideID, forward: forward)
                } else {
                    self.noArtResolved(for: slideID)
                }
            }
        }

        private func applyResolved(_ image: UIImage, url: URL, id: String, forward: Bool) {
            guard id == targetID else { return } // superseded mid-load
            guard let container else { return }

            // First real paint: place with no animation.
            if displayedID == nil || container.frontImage == nil {
                container.setInitialImage(image)
                displayedID = id
                displayedURL = url
                return
            }
            // A wipe is in flight: stash the newest resolved target and reconcile
            // on completion (this also covers "paged away then back" mid-wipe).
            if isAnimating {
                pending = (image, url, id, forward)
                return
            }
            // Already settled on this slide (art resolved to the same slide): just
            // ensure the freshest art, no wipe.
            if id == displayedID {
                if url != displayedURL {
                    container.frontImage = image
                    displayedURL = url
                }
                return
            }
            startWipe(to: image, url: url, id: id, forward: forward)
        }

        /// Couldn't resolve any art for the slide. Keep whatever is on screen (never
        /// flash to empty). If a wipe is in flight, stash the id so `drainPending`
        /// reconciles it on completion; otherwise mark it displayed at rest.
        private func noArtResolved(for id: String) {
            guard id == targetID else { return }
            if isAnimating {
                pendingNoArtID = id
                return
            }
            displayedID = id
            displayedURL = nil
        }

        /// Upgrade the *currently displayed* slide's art in place (no wipe) if a
        /// better candidate is now cached. Guarded to the displayed slide so a
        /// still-loading pending target can never swap the visible art without its
        /// wipe.
        private func maybeUpgradeDisplayedArt(urls: [URL]) {
            guard !isAnimating, targetID == displayedID, let container else { return }
            guard let (image, url) = firstUsableCached(urls), url != displayedURL else { return }
            container.frontImage = image
            displayedURL = url
        }

        private func startWipe(to image: UIImage, url: URL, id: String, forward: Bool) {
            guard let container else { return }
            isAnimating = true
            container.prepareWipe(incomingImage: image, forward: forward)

            let animator = UIViewPropertyAnimator(
                duration: duration,
                timingParameters: UICubicTimingParameters(animationCurve: .easeInOut)
            )
            animator.addAnimations { container.runWipeAnimations(forward: forward) }
            animator.addCompletion { [weak self, weak container] _ in
                guard let self, let container else { return }
                container.finishWipe()
                self.displayedID = id
                self.displayedURL = url
                self.isAnimating = false
                self.animator = nil
                self.drainPending()
            }
            self.animator = animator
            animator.startAnimation()
        }

        /// After a wipe completes, reconcile with the newest requested target: if
        /// it differs from what just settled, wipe on to it (rapid paging coalesces
        /// to a single follow-up wipe); if it's the same slide but fresher art, swap
        /// in place; if the newest target resolved to no art, accept it as displayed
        /// so state never stalls and a later cached upgrade for it can still apply.
        private func drainPending() {
            defer { pendingNoArtID = nil }
            if let pending, pending.id == targetID {
                self.pending = nil
                if pending.id != displayedID {
                    startWipe(to: pending.image, url: pending.url, id: pending.id, forward: pending.forward)
                } else if pending.url != displayedURL, let container {
                    container.frontImage = pending.image
                    displayedURL = pending.url
                }
                return
            }
            self.pending = nil
            if let noArt = pendingNoArtID, noArt == targetID, noArt != displayedID {
                displayedID = noArt
                displayedURL = nil
            }
        }

        // MARK: - Loading

        private func firstUsableCached(_ urls: [URL]) -> (UIImage, URL)? {
            for url in urls {
                guard let cached = ArtworkImageCache.shared.cachedImage(for: url) else { continue }
                if isUsable(cached) { return (cached, url) }
            }
            return nil
        }

        private func firstUsableLoaded(
            _ urls: [URL],
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) async -> (UIImage, URL)? {
            for url in urls {
                guard let loaded = await ArtworkImageCache.shared.image(for: url) else { continue }
                if isUsable(loaded) { return (loaded, url) }
            }
            if let asyncFallbackURL, let url = await asyncFallbackURL(),
               let loaded = await ArtworkImageCache.shared.image(for: url), isUsable(loaded) {
                return (loaded, url)
            }
            return nil
        }

        private func isUsable(_ image: UIImage) -> Bool {
            let size = image.size
            guard size.height > 0 else { return false }
            return size.width / size.height <= maxAspectRatio
        }
    }
}

/// The UIKit view that owns the parallax-wipe transition. Hosts two "page" layers,
/// each a clipping container with an oversized inner `UIImageView`:
/// - The **page** slides the full slide width (the push).
/// - The **inner image** translates a smaller amount within its (clipping) page —
///   the parallax "settle". It is oversized by `bleed` on each side so its
///   translation never exposes a blank edge.
///
/// Z-order is set explicitly via `layer.zPosition` at the start of every wipe —
/// the incoming page is *always* on top — so the render order is deterministic and
/// cannot be reordered by SwiftUI, `layoutSubviews`, or the animator.
final class HeroWipeContainerView: UIView {
    private let bleed: CGFloat

    private let pageA = SlidePage()
    private let pageB = SlidePage()
    /// The page currently showing the settled art.
    private var front: SlidePage
    private var back: SlidePage { front === pageA ? pageB : pageA }

    /// Authoritative slide size (from SwiftUI's frame). Preferred over `bounds` so
    /// offset math is correct even before the first layout pass.
    var slideSize: CGSize = .zero {
        didSet {
            guard !isAnimating, slideSize != oldValue else { return }
            layoutAtRest()
        }
    }
    private var isAnimating = false

    init(bleed: CGFloat) {
        self.bleed = bleed
        self.front = pageA
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
        pageA.bleed = bleed
        pageB.bleed = bleed
        addSubview(pageA)
        addSubview(pageB)
        pageB.isHidden = true
        pageA.layer.zPosition = 1
        pageB.layer.zPosition = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isAnimating else { return }
        layoutAtRest()
    }

    private var effectiveSize: CGSize {
        slideSize == .zero ? bounds.size : slideSize
    }

    /// Rest state: `front` fills the container with its image centered; `back` is
    /// hidden and parked at center.
    private func layoutAtRest() {
        let rect = CGRect(origin: .zero, size: effectiveSize)
        front.frame = rect
        front.parallax = 0
        front.isHidden = false
        front.layer.zPosition = 1
        back.frame = rect
        back.parallax = 0
        back.isHidden = true
        back.layer.zPosition = 0
    }

    // MARK: - Front image accessor (no animation)

    var frontImage: UIImage? {
        get { front.image }
        set { front.image = newValue }
    }

    func setInitialImage(_ image: UIImage) {
        front.image = image
        layoutAtRest()
    }

    // MARK: - Wipe lifecycle

    /// Stage the incoming page off-screen on the entering edge, on top, with its
    /// image content pre-offset for the parallax settle. Called synchronously,
    /// before the animation, so the z-order is committed deterministically.
    func prepareWipe(incomingImage: UIImage, forward: Bool) {
        isAnimating = true
        let size = effectiveSize
        let width = size.width
        let incoming = back
        let outgoing = front

        // Deterministic z-order: incoming always on top.
        incoming.layer.zPosition = 1
        outgoing.layer.zPosition = 0

        outgoing.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        outgoing.parallax = 0
        outgoing.isHidden = false

        incoming.image = incomingImage
        incoming.frame = CGRect(x: forward ? width : -width, y: 0, width: width, height: size.height)
        // Content leads its page from the entering side, then settles to 0.
        incoming.parallax = forward ? bleed : -bleed
        incoming.isHidden = false
    }

    /// The animatable step: both pages push the full width; the inner image content
    /// moves at a slower rate (incoming settles to 0; outgoing lags behind its page).
    func runWipeAnimations(forward: Bool) {
        let size = effectiveSize
        let width = size.width
        let incoming = back
        let outgoing = front

        incoming.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        incoming.parallax = 0

        outgoing.frame = CGRect(x: forward ? -width : width, y: 0, width: width, height: size.height)
        // Outgoing content "holds on": drifts opposite its page at ~half the bleed.
        outgoing.parallax = forward ? bleed * 0.5 : -bleed * 0.5
    }

    /// Promote the incoming page to `front`, reset and hide the outgoing page.
    func finishWipe() {
        let incoming = back
        let outgoing = front
        front = incoming

        let rect = CGRect(origin: .zero, size: effectiveSize)
        incoming.frame = rect
        incoming.parallax = 0
        incoming.layer.zPosition = 1

        outgoing.isHidden = true
        outgoing.image = nil
        outgoing.parallax = 0
        outgoing.frame = rect
        outgoing.layer.zPosition = 0

        isAnimating = false
    }
}

/// A single hero "page": a clipping container with an oversized inner image view.
/// The page frame does the horizontal push; the inner image's own transform does
/// the parallax, and it is oversized by `bleed` on each side so translating it can
/// never reveal a blank edge.
private final class SlidePage: UIView {
    private let imageView = UIImageView()
    var bleed: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    /// Horizontal parallax translation of the image content within the page.
    var parallax: CGFloat {
        get { imageView.transform.tx }
        set { imageView.transform = CGAffineTransform(translationX: newValue, y: 0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Oversize the image view by `bleed` on each side, centered, preserving any
        // active parallax translation.
        let translation = imageView.transform
        imageView.transform = .identity
        imageView.frame = bounds.insetBy(dx: -bleed, dy: 0)
        imageView.transform = translation
    }
}
#endif
#endif
