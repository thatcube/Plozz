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
/// with the real Apple TV effect: a **wipe with content parallax**. See
/// ``HeroWipeContainerView``:
/// - two page layers with **explicit, fixed `zPosition`** (incoming always on top)
///   so the render order is deterministic and immune to SwiftUI/​layout churn;
/// - the incoming page is *revealed by a clip window that grows from the entering
///   edge* — the old image stays in place and is progressively covered, rather than
///   both sliding the full width;
/// - within that window the incoming art is shifted toward the entering edge and
///   *settles* to center (and the outgoing art drifts a little, slowly) — the depth
///   cue that makes it read as parallax. You never see the incoming image's true
///   left edge until it lands.
/// - it rides an **ease-out** curve (fast in, gently decelerating to the settle).
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
    /// How far UP (points) to translate the backdrop when the hero recedes: 0 at
    /// rest, `recedeLift` when receded. Animated internally on a slow 1.6s smooth
    /// curve so the artwork keeps gliding up for ~1s after the content lift settles
    /// (the Apple TV feel).
    var recedeLift: CGFloat = 0
    /// Whether the hero is receded (focus moved down to Continue Watching). At rest
    /// the right side keeps its vivid image (the hero looks its best); when receded
    /// the right side melts into the app background much more — like the left — so
    /// the whole backdrop blends together as you browse the rows below, instead of
    /// leaving a hard image edge on the right.
    var receded: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    private var isLight: Bool { colorScheme == .light }

    /// Right-side "keep the image" strength for the dissolve. Full at rest, low when
    /// receded so the right melts into the page like the left.
    private var rightKeep: CGFloat { receded ? 0.12 : 1.0 }

    /// Height fraction at which the bottom melt BEGINS on the left. Theme-aware:
    /// light mode starts much higher (a taller, gentler fade) because the revealed
    /// **white** background contrasts hard with the artwork and needs a long runway
    /// to hide the edge; dark mode reveals **black**, which blends with dark image
    /// edges, so it can start lower and stay compact.
    private var meltStart: CGFloat { isLight ? 0.38 : 0.62 }

    /// Where the RIGHT side begins melting — lower than `meltStart` so the subject
    /// on the right keeps more image, but sharing the exact same eased tail (both
    /// reach clear at the very bottom) so the two fades blend with no seam.
    private var rightMeltStart: CGFloat { isLight ? 0.60 : 0.80 }

    var body: some View {
        backdropImage
            .frame(width: width, height: height)
            .clipped()
            .overlay(scrim)
            .mask(dissolveMask)
            .frame(maxWidth: .infinity, alignment: .center)
            // The recede rise MUST be applied here, BEFORE .ignoresSafeArea().
            // An .offset() applied AFTER .ignoresSafeArea() (as this view is when
            // hosted as a `.background` on tvOS) is silently cancelled: the
            // safe-area breakout re-anchors the view to the physical screen edge
            // on every layout pass, nullifying any outer translation. This inner
            // offset — the child of .ignoresSafeArea — is the only reliable place.
            .offset(y: -recedeLift)
            // Glide the artwork up/down on recede, lagging the content lift a touch
            // for the Apple TV parallax feel (but not sluggish). The right-side
            // dissolve strengthening rides the same curve so it blends in step.
            .animation(.smooth(duration: 0.96), value: recedeLift)
            .animation(.smooth(duration: 0.96), value: receded)
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

    /// A smooth, EASED vertical fade from opaque (`white × peak`) down to `clear`,
    /// holding solid until `start` then easing out to the very bottom. The extra
    /// intermediate stops give an ease-out shape so the melt reads as a gentle,
    /// gradual dissolve rather than a hard linear band. Both dissolve layers use
    /// this same curve shape, so they never produce a mismatched-curve seam.
    private func easedVerticalFade(start: CGFloat, peak: CGFloat = 1.0) -> LinearGradient {
        let span = max(1 - start, 0.0001)
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(peak), location: 0.0),
                .init(color: .white.opacity(peak), location: start),
                .init(color: .white.opacity(peak * 0.72), location: start + span * 0.32),
                .init(color: .white.opacity(peak * 0.36), location: start + span * 0.60),
                .init(color: .white.opacity(peak * 0.10), location: start + span * 0.83),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Bottom dissolve mask (alpha: white keeps the image, clear lets the app
    /// background show through). **Left-weighted 2D melt**: the melt is strong on
    /// the LEFT (under the title / description / paging dots) and gentle on the
    /// right so the hero subject isn't eaten there. Both layers share
    /// `easedVerticalFade` (matching multi-stop curves) and the horizontal hand-off
    /// is gradual, so the two fades blend into one smooth field with no seam — and
    /// with NO blur, so the top / left / right image edges stay crisp (a blurred
    /// mask bled transparency in from those edges). Static per appearance; only
    /// `rightKeep` (recede) and the theme change it.
    private var dissolveMask: some View {
        ZStack {
            // Base vertical melt — the strong LEFT-side dissolve to the background.
            easedVerticalFade(start: meltStart)
            // Adds the image back toward the RIGHT: a very gradual left→right lean
            // (full only at the far right, so no vertical seam) gated by an eased
            // fade that shares the base's tail. `rightKeep` drops it toward 0 on
            // recede, so the right then melts like the left.
            easedVerticalFade(start: rightMeltStart, peak: rightKeep)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.22),
                            .init(color: .white, location: 0.85)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
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
    /// Full, cinematic settle time for the newest (top) wipe. Slightly longer than a
    /// push so the easeOut "settle" tail reads clearly. Older wipes stacked beneath
    /// it are accelerated past this so a rapid burst still clears quickly.
    private static let duration: TimeInterval = 0.85
    /// Each time a newer press stacks a wipe on top, every still-running wipe has its
    /// remaining time shortened toward this fraction of its original — so the older
    /// reveals rush to the finish ("faster and faster the more you press") while the
    /// freshest press still plays at full length.
    private static let catchUpFactor: CGFloat = 0.35
    /// Tiny horizontal overscan, purely to avoid a sub-pixel seam shimmer during the
    /// wipe. Kept small so the resting image isn't zoomed / vertically cropped.
    private static let parallaxBleed: CGFloat = 8
    /// How far the incoming art is shifted toward the entering edge at the start,
    /// then settles to center — the parallax "glide." Independent of `bleed`; only
    /// needs to be ≤ the slide width.
    private static let parallaxIn: CGFloat = 1200

    func makeCoordinator() -> Coordinator {
        Coordinator(maxAspectRatio: Self.maxAspectRatio)
    }

    func makeUIView(context: Context) -> HeroWipeContainerView {
        let view = HeroWipeContainerView(
            bleed: Self.parallaxBleed,
            parallaxIn: Self.parallaxIn,
            duration: Self.duration,
            catchUpFactor: Self.catchUpFactor
        )
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

    /// Owns transition scheduling: which slide is fronted, cache-first art loading
    /// (with a monotonic token so only the newest target's art may apply), and —
    /// crucially — it hands each new slide to the container as an INDEPENDENT wipe.
    /// Rapid pages are NOT coalesced: every press stacks its own wipe on top of any
    /// still in flight (the container plays them concurrently and accelerates the
    /// older ones), so you always see one animation per press.
    @MainActor
    final class Coordinator {
        weak var container: HeroWipeContainerView?
        private let maxAspectRatio: CGFloat

        /// Identity of the slide currently fronted (the newest resolved target).
        private var displayedID: String?
        /// URL of the fronted art (for same-slide, no-wipe upgrades).
        private var displayedURL: URL?
        /// Identity of the latest requested slide (may still be loading).
        private var targetID: String?
        /// Monotonic load token; only the newest requested art may apply.
        private var loadToken = 0

        init(maxAspectRatio: CGFloat) {
            self.maxAspectRatio = maxAspectRatio
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
            if displayedID == nil || container.baseImage == nil {
                container.setInitialImage(image)
                displayedID = id
                displayedURL = url
                return
            }
            // Already fronted on this slide (art resolved to the same slide): just
            // ensure the freshest art, no wipe.
            if id == displayedID {
                if url != displayedURL {
                    container.baseImage = image
                    displayedURL = url
                }
                return
            }
            // A genuinely new slide: stack a fresh wipe ON TOP of any still in
            // flight. The container never interrupts a running wipe — it plays this
            // one over them and accelerates the older ones so the stack clears fast.
            container.pushWipe(incomingImage: image, forward: forward)
            displayedID = id
            displayedURL = url
        }

        /// Couldn't resolve any art for the newest slide. Keep whatever is on screen
        /// (never flash to empty) but record it as fronted so a later cached upgrade
        /// for it can still apply in place.
        private func noArtResolved(for id: String) {
            guard id == targetID else { return }
            displayedID = id
            displayedURL = nil
        }

        /// Upgrade the *fronted* slide's art in place (no wipe) if a better candidate
        /// is now cached. Skipped while a wipe is in flight so it can't swap the base
        /// image mid-reveal.
        private func maybeUpgradeDisplayedArt(urls: [URL]) {
            guard let container, !container.isWiping, targetID == displayedID else { return }
            guard let (image, url) = firstUsableCached(urls), url != displayedURL else { return }
            container.baseImage = image
            displayedURL = url
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

/// The UIKit view that owns the Apple TV **parallax wipe** — as a *stack of
/// concurrent reveals*. A base layer shows the settled slide; every page press adds
/// a new ``SlidePage`` ON TOP that is revealed by a clip window growing from the
/// entering edge (its art also glides in for the parallax cue).
///
/// The transition is a *wipe*, not a push, and presses are never coalesced or
/// interrupted:
/// - Each press calls ``pushWipe(incomingImage:forward:)`` which stacks a fresh
///   reveal on top of any already running (newest = highest `zPosition`). The window
///   grows from the entering edge (right→left forward; mirrored backward) while the
///   content settles to center, so the art glides in and you never see its true left
///   edge until it lands.
/// - A burst therefore shows several reveals at once. Every time a newer one is
///   pushed, the older still-running reveals are *accelerated* (never stopped) so the
///   stack clears quickly ("faster and faster the more you press") while the freshest
///   press plays at full length.
/// - A completed reveal is, by construction, a full-screen layer covering everything
///   below it — so on completion it simply becomes the new base image and every layer
///   at/below it is discarded. That makes cleanup order-independent.
///
/// All geometry is pure `frame` animation (no transforms), so it can never decompose
/// into the wrong-order artifact; z-order is explicit and monotonic.
final class HeroWipeContainerView: UIView {
    /// Tiny horizontal overscan on each page, purely to avoid a sub-pixel seam
    /// shimmer while its window animates. Coverage does not depend on it, so it stays
    /// small to avoid zooming the resting image.
    private let bleed: CGFloat
    /// How far an incoming page's content is shifted toward the entering edge at the
    /// start of its reveal, settling to 0 — the parallax "glide."
    private let parallaxIn: CGFloat
    /// Full, cinematic settle time for the newest (top) reveal.
    private let duration: TimeInterval
    /// Each time a newer press stacks a reveal on top, every still-running reveal has
    /// its remaining time shortened toward this fraction of its original — so older
    /// reveals rush to the finish. Compounds across a burst.
    private let catchUpFactor: CGFloat

    /// A single in-flight reveal: its page view and the animator driving it.
    private final class Wipe {
        let page: SlidePage
        let animator: UIViewPropertyAnimator
        init(page: SlidePage, animator: UIViewPropertyAnimator) {
            self.page = page
            self.animator = animator
        }
    }

    /// The settled slide, at the bottom of the stack (`zPosition` 0).
    private let baseLayer = SlidePage()
    /// In-flight reveals, ordered oldest → newest (newest has the highest z).
    private var wipes: [Wipe] = []
    /// Monotonic z so each new reveal sits above every earlier one; reset when idle.
    private var zCounter: CGFloat = 0

    /// Whether any reveal is currently animating.
    var isWiping: Bool { !wipes.isEmpty }

    /// Authoritative slide size (from SwiftUI's frame). Preferred over `bounds` so
    /// offset math is correct even before the first layout pass.
    var slideSize: CGSize = .zero {
        didSet {
            guard !isWiping, slideSize != oldValue else { return }
            layoutBaseAtRest()
        }
    }

    init(bleed: CGFloat, parallaxIn: CGFloat, duration: TimeInterval, catchUpFactor: CGFloat) {
        self.bleed = bleed
        self.parallaxIn = parallaxIn
        self.duration = duration
        self.catchUpFactor = catchUpFactor
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
        baseLayer.bleed = bleed
        baseLayer.layer.zPosition = 0
        addSubview(baseLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isWiping else { return }
        layoutBaseAtRest()
    }

    private var effectiveSize: CGSize {
        slideSize == .zero ? bounds.size : slideSize
    }

    /// Park the base layer full-screen with its art centered.
    private func layoutBaseAtRest() {
        let size = effectiveSize
        baseLayer.setWindow(CGRect(origin: .zero, size: size), contentX: 0, size: size)
        baseLayer.isHidden = false
    }

    // MARK: - Base image accessor (no animation)

    var baseImage: UIImage? {
        get { baseLayer.image }
        set { baseLayer.image = newValue }
    }

    /// First paint / hard reset: drop any in-flight reveals and seat the base art.
    func setInitialImage(_ image: UIImage) {
        cancelAllWipes()
        baseLayer.image = image
        layoutBaseAtRest()
    }

    // MARK: - Stacked wipe

    /// Add a reveal for `incomingImage` ON TOP of the current stack and start it
    /// immediately. Never interrupts a running reveal — it accelerates the older ones
    /// instead — so every press animates.
    func pushWipe(incomingImage: UIImage, forward: Bool) {
        let size = effectiveSize
        // No usable layout yet: just seat the art as the base.
        guard size.width > 0, size.height > 0 else {
            cancelAllWipes()
            baseLayer.image = incomingImage
            layoutBaseAtRest()
            return
        }

        // Speed up everything already in flight ("faster and faster the more you
        // press") — but never stop them; they still play to completion. The deeper
        // the burst, the harder the older reveals are hurried along.
        let burstDepth = wipes.count
        for wipe in wipes { accelerate(wipe, burstDepth: burstDepth) }

        // Stage the new page as a zero-width window on the entering edge, on top,
        // with its content pre-shifted toward that edge so it glides in as it opens.
        let page = SlidePage()
        page.bleed = bleed
        page.image = incomingImage
        zCounter += 1
        page.layer.zPosition = zCounter
        addSubview(page)
        let startWindow = forward
            ? CGRect(x: size.width, y: 0, width: 0, height: size.height)
            : CGRect(x: 0, y: 0, width: 0, height: size.height)
        page.setWindow(startWindow, contentX: forward ? parallaxIn : -parallaxIn, size: size)

        // Reveal: grow the window to full-screen while the content settles to center,
        // on a strong ease-OUT (fast in, gentle landing) via a custom expo-out cubic.
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.16, y: 1.0),
                controlPoint2: CGPoint(x: 0.3, y: 1.0)
            )
        )
        animator.addAnimations { [weak page] in
            page?.setWindow(CGRect(origin: .zero, size: size), contentX: 0, size: size)
        }
        let wipe = Wipe(page: page, animator: animator)
        animator.addCompletion { [weak self] _ in self?.complete(wipe) }
        wipes.append(wipe)
        animator.startAnimation()
    }

    /// Shorten a running reveal's remaining time so older, stacked-under reveals rush
    /// to the finish. `burstDepth` (how many reveals were already in flight) makes it
    /// "faster and faster the more you press": each extra layer clamps the remaining
    /// time down harder. Reads the paused progress so a reveal already near its end is
    /// only nudged, never slowed, and always resumes.
    private func accelerate(_ wipe: Wipe, burstDepth: Int) {
        let animator = wipe.animator
        guard animator.state == .active, animator.isRunning else { return }
        animator.pauseAnimation()
        let remaining = max(0, 1 - Double(animator.fractionComplete))
        // Deeper burst → smaller target (0.6^(depth-1)): depth1→×1, 2→×0.6, 3→×0.36…
        let depthScale = pow(0.6, Double(max(0, burstDepth - 1)))
        let target = min(Double(catchUpFactor) * depthScale, remaining * 0.9)
        let factor = max(0.05, target)
        animator.continueAnimation(
            withTimingParameters: UICubicTimingParameters(animationCurve: .easeOut),
            durationFactor: CGFloat(factor)
        )
    }

    /// A reveal finished: it is now a full-screen layer covering everything below it,
    /// so promote its art to the base and discard it and every lower layer. Layers
    /// above it keep revealing over the new base. Order-independent by construction.
    private func complete(_ wipe: Wipe) {
        guard let index = wipes.firstIndex(where: { $0 === wipe }) else { return }
        baseLayer.image = wipe.page.image
        layoutBaseAtRest()
        let doomed = Array(wipes[0...index])
        wipes.removeSubrange(0...index)
        for old in doomed {
            if old !== wipe { old.animator.stopAnimation(true) }
            old.page.removeFromSuperview()
        }
        if wipes.isEmpty { zCounter = 0 }
    }

    /// Cancel and remove every in-flight reveal (no completion side effects).
    private func cancelAllWipes() {
        for wipe in wipes {
            wipe.animator.stopAnimation(true)
            wipe.page.removeFromSuperview()
        }
        wipes.removeAll()
        zCounter = 0
    }
}

/// A single hero "page": a clipping window containing an inner image view. The
/// page's own `frame` is the visible clip window (which the wipe grows); the inner
/// image is positioned so its content maps to a fixed spot in *container* space
/// regardless of the window. It carries a tiny `bleed` overscan on each side only
/// to avoid a sub-pixel seam shimmer while the window animates.
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

    /// Set this page's clip `window` (container coords) and position the image so
    /// its logical left edge lands at `contentX` in *container* coords. Both the
    /// page frame and the inner image frame are set here; animating a `setWindow`
    /// call from one state to another (within one animator's curve) interpolates
    /// both together, so the content stays correctly anchored at every frame.
    ///
    /// No transform is used — only `frame` — so this is safe to animate and never
    /// hits the frame/transform corruption gotcha.
    func setWindow(_ window: CGRect, contentX: CGFloat, size: CGSize) {
        frame = window
        // The image spans [contentX - bleed, contentX + size.width + bleed] in
        // container coords; convert to this page's local coords (subtract origin).
        imageView.frame = CGRect(
            x: contentX - bleed - window.origin.x,
            y: 0,
            width: size.width + 2 * bleed,
            height: size.height
        )
    }
}
#endif
#endif
