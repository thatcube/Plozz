#if canImport(SwiftUI)
import SwiftUI
import CoreUI
import CoreModels
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
/// - a transient page stack with **explicit `zPosition`** (each incoming page on
///   top) so rapid wipes overlap without interrupting one another;
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
    /// Ordered candidate backdrop references for the **currently fronted** slide.
    let references: [ArtworkReference]
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

    init(
        references: [ArtworkReference],
        asyncFallbackURL: (@Sendable () async -> URL?)?,
        slideID: String,
        forward: Bool,
        width: CGFloat,
        height: CGFloat,
        scrimTone: Color,
        recedeLift: CGFloat = 0,
        receded: Bool = false
    ) {
        self.references = references
        self.asyncFallbackURL = asyncFallbackURL
        self.slideID = slideID
        self.forward = forward
        self.width = width
        self.height = height
        self.scrimTone = scrimTone
        self.recedeLift = recedeLift
        self.receded = receded
    }

    init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)?,
        slideID: String,
        forward: Bool,
        width: CGFloat,
        height: CGFloat,
        scrimTone: Color,
        recedeLift: CGFloat = 0,
        receded: Bool = false
    ) {
        self.init(
            references: urls.map(ArtworkReference.remote),
            asyncFallbackURL: asyncFallbackURL,
            slideID: slideID,
            forward: forward,
            width: width,
            height: height,
            scrimTone: scrimTone,
            recedeLift: recedeLift,
            receded: receded
        )
    }

    @Environment(\.colorScheme) private var colorScheme
    private var isLight: Bool { colorScheme == .light }

    /// Height fraction at which the bottom melt BEGINS. Theme-aware: light mode
    /// starts much higher (a taller, gentler fade) because the revealed **white**
    /// background contrasts hard with the artwork and needs a long runway to hide
    /// the edge; dark mode reveals **black**, which blends with dark image edges,
    /// so it can start lower and stay compact. Applied uniformly across the whole
    /// width (see `dissolveMask`).
    private var meltStart: CGFloat { isLight ? 0.38 : 0.62 }

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
            references: references,
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

    /// Legibility scrim: a seamless edge vignette (same darkening on every side)
    /// plus a faint all-over wash, replacing the old left-only horizontal wash so
    /// the darkening blends evenly across the whole hero instead of pooling on the
    /// left — especially over bright art. `edgePeak` matches the old left strength
    /// (0.55) so the content side is never lightened. Lives under the dissolve
    /// mask so it fades away with the image at the bottom and never tints the
    /// revealed background. Static across slides, so it never animates.
    private var scrim: some View {
        HeroLegibilityScrim(tone: scrimTone, edgePeak: 0.55)
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
    /// Dissolves the backdrop into the page along the bottom. A single, SYMMETRIC
    /// vertical melt across the entire width, so the artwork fades gradually into
    /// the background along the whole bottom edge — not higher on the left than the
    /// right (the old left-weighted melt). When receded the melt begins higher so
    /// more of the backdrop blends into the rows below. Static per appearance; only
    /// `receded` and the theme change it.
    private var dissolveMask: some View {
        easedVerticalFade(start: receded ? recededMeltStart : meltStart)
    }

    /// Where the uniform melt begins when receded — higher up than at rest, so the
    /// whole backdrop blends further into the page as you browse the rows below.
    private var recededMeltStart: CGFloat { max(0.1, meltStart - 0.2) }
}

#if canImport(UIKit)
/// Shared hero-art acceptance policy. Some providers expose ultra-wide logo/banner
/// assets through backdrop fields; treating those as full-bleed art both looks wrong
/// and can suppress warming of a valid fallback.
enum HeroBackdropArtworkPolicy {
    static let maxAspectRatio: CGFloat = 3.0

    static func isUsable(_ image: UIImage) -> Bool {
        let size = image.size
        guard size.height > 0 else { return false }
        return size.width / size.height <= maxAspectRatio
    }

    static func hasUsableCachedArtwork(for references: [ArtworkReference]) -> Bool {
        let cache = ArtworkImageCache.shared
        return references.contains { reference in
            [.heroBackdrop, .landscapeCard, .heroPreview].contains { variant in
                cache.cachedImage(for: reference, variant: variant).map(isUsable) == true
            }
        }
    }

    /// Warms candidates in display order until one yields a usable instant frame.
    /// A malformed primary must not prevent a valid fallback from becoming cache-hot.
    static func warmFirstUsablePreview(for references: [ArtworkReference]) async -> Bool {
        if hasUsableCachedArtwork(for: references) { return true }
        for reference in references {
            guard !Task.isCancelled else { return false }
            if let image = await ArtworkImageCache.shared.image(
                for: reference,
                variant: .heroPreview,
                background: true
            ), !Task.isCancelled, isUsable(image) {
                return true
            }
        }
        return false
    }

    static func hasUsableCachedArtwork(for urls: [URL]) -> Bool {
        hasUsableCachedArtwork(for: urls.map(ArtworkReference.remote))
    }

    static func warmFirstUsablePreview(for urls: [URL]) async -> Bool {
        await warmFirstUsablePreview(for: urls.map(ArtworkReference.remote))
    }
}

/// SwiftUI bridge for the parallax-wipe backdrop. The representable is *inert*:
/// it only forwards the fronted slide's identity/URLs/direction to the coordinator,
/// which owns the entire Core Animation transition. Because SwiftUI never animates
/// the image layers, it can never decompose the wipe into wrong-order pieces.
private struct WipeImageView: UIViewRepresentable {
    let references: [ArtworkReference]
    let asyncFallbackURL: (@Sendable () async -> URL?)?
    let slideID: String
    let forward: Bool
    let width: CGFloat
    let height: CGFloat

    /// Slightly longer than a push so the easeOut "settle" tail reads clearly.
    /// Tuned by feel: 0.85 → 0.95 → 1.20 → 1.05. Both the wipe and the (slightly
    /// slower) leaving-image drift scale with this, so changing it speeds/slows the
    /// whole transition uniformly and preserves their relative trail.
    private static let duration: TimeInterval = 1.05
    /// Tiny horizontal overscan, purely to avoid a sub-pixel seam shimmer during the
    /// wipe. It is intentionally small: in the wipe model the incoming content is
    /// shifted *into* the revealed area and the outgoing only drifts a little, so
    /// full coverage holds without a large overscan (which would otherwise zoom /
    /// vertically-crop the resting image).
    private static let parallaxBleed: CGFloat = 8
    /// How far the incoming art is shifted toward the entering edge at the start,
    /// then settles to center — the parallax "glide." Independent of `bleed`; only
    /// needs to be ≤ the slide width.
    private static let parallaxIn: CGFloat = 1200
    /// How far the outgoing art drifts as it is covered by the wipe, as a FRACTION
    /// of the slide width (so the distance is robust to the actual size). At 0.625
    /// the leaving art travels ~1200pt (of the 1920 tvOS width) while the reveal
    /// sweeps the full width on the same curve — a strong parallax that reads as
    /// moving *with* the wipe. Seam-safe for any fraction ≤ 1 with the shared curve
    /// (the reveal covers the full width, always outpacing the blank strip the drift
    /// opens).
    private static let driftFraction: CGFloat = 0.625

    func makeCoordinator() -> Coordinator {
        Coordinator(duration: Self.duration)
    }

    func makeUIView(context: Context) -> HeroWipeContainerView {
        let view = HeroWipeContainerView(
            bleed: Self.parallaxBleed,
            parallaxIn: Self.parallaxIn,
            driftFraction: Self.driftFraction
        )
        context.coordinator.container = view
        context.coordinator.configure(width: width, height: height)
        context.coordinator.update(
            references: references, slideID: slideID, forward: forward, asyncFallbackURL: asyncFallbackURL
        )
        return view
    }

    func updateUIView(_ uiView: HeroWipeContainerView, context: Context) {
        context.coordinator.container = uiView
        context.coordinator.configure(width: width, height: height)
        context.coordinator.update(
            references: references, slideID: slideID, forward: forward, asyncFallbackURL: asyncFallbackURL
        )
    }

    static func dismantleUIView(_ uiView: HeroWipeContainerView, coordinator: Coordinator) {
        coordinator.cancelPendingLoad()
    }

    // MARK: - Coordinator

    /// Owns transition scheduling: which slide is displayed, cache-first art loading
    /// (with a monotonic token so only the newest unresolved target can apply), and a
    /// stack of independent animators so every rapid cached page keeps playing while
    /// the next wipe opens directly above it.
    @MainActor
    final class Coordinator {
        weak var container: HeroWipeContainerView?
        private let duration: TimeInterval

        /// Identity of the slide currently settled on screen.
        private var displayedID: String?
        /// URL and resolution tier of the art currently fronted (for same-slide
        /// progressive upgrades).
        private var displayedReference: ArtworkReference?
        private var displayedQuality: ArtworkQuality?
        /// Identity of the latest requested slide (may still be loading).
        private var targetID: String?
        /// Latest candidate URLs for `targetID`, retained so a same-slide artwork
        /// upgrade arriving mid-wipe can be applied when the wipe lands.
        private var targetReferences: [ArtworkReference] = []
        private var targetForward = true
        /// Monotonic load token; only the newest requested art may apply.
        private var loadToken = 0
        /// The one foreground artwork load that can still become visible. Paging
        /// cancels the previous task so skipped cold slides release their cache
        /// waiter, download, and decode instead of competing with the latest press.
        private var loadTask: Task<Void, Never>?
        private enum ArtworkQuality: Int {
            case preview
            case full
        }
        /// Retains every active pair until its incoming reveal finishes. Each press
        /// gets its own pair; no animator is stopped to make room for another.
        private struct ActiveAnimations {
            let incoming: UIViewPropertyAnimator
            let outgoing: UIViewPropertyAnimator?
        }
        private var activeAnimations: [UUID: ActiveAnimations] = [:]

        init(duration: TimeInterval) {
            self.duration = duration
        }

        func configure(width: CGFloat, height: CGFloat) {
            container?.slideSize = CGSize(width: width, height: height)
        }

        func cancelPendingLoad() {
            loadToken += 1
            loadTask?.cancel()
            loadTask = nil
        }

        func update(
            references: [ArtworkReference],
            slideID: String,
            forward: Bool,
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) {
            targetForward = forward
            // Same slide already shown/targeted: this is one of the countless
            // non-paging SwiftUI updates (scroll, focus, parallax). Free — except
            // we opportunistically upgrade the *displayed* slide's art if a better
            // (higher-res / router-resolved) candidate has since been cached.
            if slideID == targetID {
                if references != targetReferences {
                    targetReferences = references
                    resolveSameSlideUpgrade(
                        references: references,
                        slideID: slideID,
                        asyncFallbackURL: asyncFallbackURL
                    )
                } else {
                    maybeUpgradeDisplayedArt(references: references)
                }
                return
            }
            targetID = slideID
            targetReferences = references
            beginProgressiveResolution(
                references: references,
                slideID: slideID,
                forward: forward,
                asyncFallbackURL: asyncFallbackURL
            )
        }

        /// Fronts the best synchronously cached image immediately, then keeps one
        /// cancellable task alive to progressively upgrade a preview to full hero
        /// resolution. The preview tier first reuses a decoded landscape card (free
        /// when Home already showed it), then the dedicated 768px hero preview.
        private func beginProgressiveResolution(
            references: [ArtworkReference],
            slideID: String,
            forward: Bool,
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) {
            loadTask?.cancel()
            loadTask = nil
            loadToken += 1
            let token = loadToken

            var provisionalFullApplied = false
            if let (image, reference) = firstUsableCached(references, variant: .heroBackdrop) {
                applyResolved(
                    image,
                    reference: reference,
                    quality: .full,
                    id: slideID,
                    forward: forward
                )
                if reference == references.first {
                    return
                }
                provisionalFullApplied = true
            }

            let cachedPreview = provisionalFullApplied
                ? nil
                : firstUsableCached(references, variant: .landscapeCard)
                    ?? firstUsableCached(references, variant: .heroPreview)
            let previewWasApplied = provisionalFullApplied || cachedPreview != nil
            if let (image, reference) = cachedPreview {
                applyResolved(
                    image,
                    reference: reference,
                    quality: .preview,
                    id: slideID,
                    forward: forward
                )
            }

            loadTask = Task { [weak self] in
                guard let self else { return }
                var previewApplied = previewWasApplied
                if !previewApplied {
                    let preview = await self.firstUsableLoaded(
                        references,
                        variant: .heroPreview,
                        asyncFallbackURL: asyncFallbackURL
                    )
                    guard !Task.isCancelled, token == self.loadToken else { return }
                    if let (image, reference) = preview {
                        self.applyResolved(
                            image,
                            reference: reference,
                            quality: .preview,
                            id: slideID,
                            forward: forward
                        )
                        previewApplied = true
                    }
                }

                let resolved = await self.firstUsableLoaded(
                    references,
                    variant: .heroBackdrop,
                    asyncFallbackURL: asyncFallbackURL
                )
                guard !Task.isCancelled, token == self.loadToken else { return }
                self.loadTask = nil
                if let (image, reference) = resolved {
                    self.applyResolved(
                        image,
                        reference: reference,
                        quality: .full,
                        id: slideID,
                        forward: forward
                    )
                } else if !previewApplied {
                    self.noArtResolved(for: slideID)
                }
            }
        }

        private func applyResolved(
            _ image: UIImage,
            reference: ArtworkReference,
            quality: ArtworkQuality,
            id: String,
            forward: Bool
        ) {
            guard id == targetID else { return } // superseded mid-load
            guard let container else { return }

            // First real paint: place with no animation.
            if !container.hasPages {
                container.setInitialImage(image)
                displayedID = id
                displayedReference = reference
                displayedQuality = quality
                return
            }
            // Same target: replace only when the URL changes at an equal tier, or
            // resolution improves. Swapping the top page's UIImage leaves its reveal
            // geometry and animator untouched, so preview → full never restarts the
            // wipe and a late preview can never downgrade a full frame.
            if id == displayedID {
                let currentQuality = displayedQuality ?? .preview
                guard quality.rawValue >= currentQuality.rawValue else { return }
                guard reference != displayedReference || quality != displayedQuality else { return }
                container.frontImage = image
                displayedReference = reference
                displayedQuality = quality
                return
            }
            startWipe(to: image, reference: reference, id: id, forward: forward)
            displayedID = id
            displayedReference = reference
            displayedQuality = quality
        }

        /// Couldn't resolve any art for the slide. Clear stale art rather than
        /// displaying the previous title's backdrop under the new title's metadata.
        private func noArtResolved(for id: String) {
            guard id == targetID else { return }
            container?.clear()
            displayedID = id
            displayedReference = nil
            displayedQuality = nil
        }

        /// Upgrade the *currently displayed* slide's art in place (no wipe) if a
        /// better candidate is now cached. Guarded to the displayed slide so a
        /// still-loading target can never swap the visible art without its wipe.
        private func maybeUpgradeDisplayedArt(references: [ArtworkReference]) {
            guard targetID == displayedID, let container else { return }
            guard let (image, reference) = firstUsableCached(references, variant: .heroBackdrop) else { return }
            guard displayedQuality != .full || reference != displayedReference else { return }
            if container.hasPages {
                container.frontImage = image
            } else {
                container.setInitialImage(image)
            }
            displayedReference = reference
            displayedQuality = .full
        }

        private func startWipe(to image: UIImage, reference: ArtworkReference, id: String, forward: Bool) {
            guard let container else { return }
            let prepared = container.prepareWipe(incomingImage: image, forward: forward)
            let animationID = UUID()

            // The two pages ride DIFFERENT curves on purpose: the wipe keeps its
            // original snappy speed, and the leaving art trails it a little (a parallax
            // lag), rather than matching it.
            //
            // Incoming reveal — the original expo-out: near-instant off the mark,
            // easing softly into the landing. This is "the wipe," unchanged in speed.
            let incomingCurve = UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.16, y: 1.0),
                controlPoint2: CGPoint(x: 0.3, y: 1.0)
            )
            // Outgoing drift — the SAME front-loaded character (prompt start, no linger,
            // settles) but a notch gentler, so the leaving art is a little slower than
            // the wipe and visibly trails it. Its control-point x's are pushed right so
            // it reaches the landing slightly later than the reveal. Seam-safe: it is
            // strictly slower than the reveal at every instant, so the reveal (covering
            // the full width) always stays ahead of the fractional drift.
            let outgoingCurve = UICubicTimingParameters(
                controlPoint1: CGPoint(x: 0.22, y: 1.0),
                controlPoint2: CGPoint(x: 0.44, y: 1.0)
            )

            // Incoming page: the reveal. Owns completion.
            let incomingAnimator = UIViewPropertyAnimator(
                duration: duration,
                timingParameters: incomingCurve
            )
            incomingAnimator.addAnimations {
                container.animateIncoming(prepared.incoming)
            }
            incomingAnimator.addCompletion { [weak self, weak container] _ in
                guard let self, let container else { return }
                container.finishWipe(prepared.incoming)
                self.activeAnimations[animationID] = nil
                if self.targetID == id {
                    self.maybeUpgradeDisplayedArt(references: self.targetReferences)
                }
            }

            // Outgoing page: the leaving art drifts on its own slightly-slower curve, so
            // it trails the wipe. It animates a nested content wrapper, so the drift
            // never interrupts that page's own reveal.
            let outgoingAnimator = prepared.outgoing.map { outgoing in
                let animator = UIViewPropertyAnimator(
                    duration: duration,
                    timingParameters: outgoingCurve
                )
                animator.addAnimations {
                    container.animateOutgoing(outgoing, forward: forward)
                }
                return animator
            }

            activeAnimations[animationID] = ActiveAnimations(
                incoming: incomingAnimator,
                outgoing: outgoingAnimator
            )
            incomingAnimator.startAnimation()
            outgoingAnimator?.startAnimation()
        }

        private func resolveSameSlideUpgrade(
            references: [ArtworkReference],
            slideID: String,
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) {
            beginProgressiveResolution(
                references: references,
                slideID: slideID,
                forward: targetForward,
                asyncFallbackURL: asyncFallbackURL
            )
        }

        // MARK: - Loading

        private func firstUsableCached(
            _ references: [ArtworkReference],
            variant: ArtworkImageVariant
        ) -> (UIImage, ArtworkReference)? {
            for reference in references {
                guard let cached = ArtworkImageCache.shared.cachedImage(
                    for: reference,
                    variant: variant
                ) else { continue }
                if HeroBackdropArtworkPolicy.isUsable(cached) { return (cached, reference) }
            }
            return nil
        }

        private func firstUsableLoaded(
            _ references: [ArtworkReference],
            variant: ArtworkImageVariant,
            asyncFallbackURL: (@Sendable () async -> URL?)?
        ) async -> (UIImage, ArtworkReference)? {
            for reference in references {
                guard !Task.isCancelled else { return nil }
                guard let loaded = await ArtworkImageCache.shared.image(
                    for: reference,
                    variant: variant
                ) else { continue }
                guard !Task.isCancelled else { return nil }
                if HeroBackdropArtworkPolicy.isUsable(loaded) { return (loaded, reference) }
            }
            guard !Task.isCancelled else { return nil }
            if let asyncFallbackURL, let url = await asyncFallbackURL() {
                guard !Task.isCancelled else { return nil }
                if let loaded = await ArtworkImageCache.shared.image(for: url, variant: variant),
                   !Task.isCancelled,
                   HeroBackdropArtworkPolicy.isUsable(loaded) {
                    return (loaded, .remote(url))
                }
            }
            return nil
        }
    }
}

/// The UIKit view that owns the Apple TV **parallax wipe**. Hosts a transient stack
/// of pages: each new press adds an incoming page above every active wipe, so older
/// reveals continue underneath instead of being completed or cancelled.
///
/// The transition is a *wipe*, not a push:
/// - The **incoming** page is on top and is *revealed by a clip window that grows
///   from the entering edge* (right→left when paging forward; mirrored backward).
///   Its content is also shifted toward that edge at the start and *settles* to
///   center — so the art glides in (parallax) and you never see its true left edge
///   until it lands.
/// - The **outgoing** page sits underneath, essentially in place, drifting only a
///   little (and slowly) as it is progressively *covered* by the wipe.
///
/// Each page isolates its reveal geometry from its outgoing drift: the clip window
/// and content center animate on separate views, so a page can keep revealing while
/// the next page starts drifting it underneath. Completed pages prune only layers
/// they fully cover; active layers above them remain untouched.
final class HeroWipeContainerView: UIView {
    struct WipeHandle {
        fileprivate let page: SlidePage
    }

    struct PreparedWipe {
        let incoming: WipeHandle
        let outgoing: WipeHandle?
    }

    /// Tiny horizontal overscan on each inner image view, purely to avoid a
    /// sub-pixel seam shimmer during the wipe. Coverage does *not* depend on it in
    /// the wipe model, so it stays small to avoid zooming the resting image.
    private let bleed: CGFloat
    /// How far the *incoming* content is shifted toward the entering edge at the
    /// start of a wipe, settling to 0 — the parallax "glide."
    private let parallaxIn: CGFloat
    /// How far the *outgoing* content drifts away as it is covered, as a fraction of
    /// the slide width (multiplied by `effectiveSize.width` at animate time).
    private let driftFraction: CGFloat

    private var pages: [SlidePage] = []
    private var revealingPages = Set<ObjectIdentifier>()

    var hasPages: Bool { !pages.isEmpty }
    var pageCount: Int { pages.count }
    var activeWipeCount: Int { revealingPages.count }

    /// Authoritative slide size (from SwiftUI's frame). Preferred over `bounds` so
    /// offset math is correct even before the first layout pass.
    var slideSize: CGSize = .zero {
        didSet {
            guard revealingPages.isEmpty, slideSize != oldValue else { return }
            layoutAtRest()
        }
    }

    init(bleed: CGFloat, parallaxIn: CGFloat, driftFraction: CGFloat) {
        self.bleed = bleed
        self.parallaxIn = parallaxIn
        self.driftFraction = driftFraction
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard revealingPages.isEmpty else { return }
        layoutAtRest()
    }

    private var effectiveSize: CGSize {
        slideSize == .zero ? bounds.size : slideSize
    }

    /// Rest state: only the top page remains and fills the container.
    private func layoutAtRest() {
        guard let front = pages.last else { return }
        for obsolete in pages.dropLast() {
            obsolete.removeFromSuperview()
        }
        pages = [front]
        let size = effectiveSize
        let full = CGRect(origin: .zero, size: size)
        front.resetOutgoingDrift()
        front.setWindow(full, contentX: 0, size: size)
        front.layer.zPosition = 0
    }

    // MARK: - Front image accessor (no animation)

    var frontImage: UIImage? {
        get { pages.last?.image }
        set { pages.last?.image = newValue }
    }

    func setInitialImage(_ image: UIImage?) {
        clear()
        let page = makePage(image: image)
        addSubview(page)
        pages = [page]
        layoutAtRest()
    }

    func clear() {
        for page in pages {
            page.removeFromSuperview()
        }
        revealingPages.removeAll()
        pages.removeAll()
    }

    // MARK: - Wipe lifecycle

    /// Stage the incoming page as a *zero-width window* pinned to the entering edge,
    /// on top, with its content pre-shifted toward that edge for the parallax glide.
    /// Called synchronously, before the animation, so z-order is deterministic.
    func prepareWipe(incomingImage: UIImage, forward: Bool) -> PreparedWipe {
        if pages.isEmpty {
            setInitialImage(nil)
        }
        let size = effectiveSize
        let outgoing = pages.last
        let incoming = makePage(image: incomingImage)

        // Incoming: zero-width window on the entering edge (forward → right edge,
        // opening leftward; backward → left edge, opening rightward). Content is
        // shifted toward the entering edge so it glides in as the window opens.
        let startWindow = forward
            ? CGRect(x: size.width, y: 0, width: 0, height: size.height)
            : CGRect(x: 0, y: 0, width: 0, height: size.height)
        incoming.setWindow(startWindow, contentX: forward ? parallaxIn : -parallaxIn, size: size)
        incoming.layer.zPosition = CGFloat(pages.count)
        addSubview(incoming)
        pages.append(incoming)
        revealingPages.insert(ObjectIdentifier(incoming))

        return PreparedWipe(
            incoming: WipeHandle(page: incoming),
            outgoing: outgoing.map { WipeHandle(page: $0) }
        )
    }

    /// The animatable step, split so each page can ride its own timing curve.
    /// `animateIncoming` opens the reveal window to full-screen while the incoming
    /// content settles to center (driven ease-out); `animateOutgoing` translates a
    /// nested content wrapper slowly the other way (driven ease-in).
    func animateIncoming(_ handle: WipeHandle) {
        let size = effectiveSize
        handle.page.setWindow(CGRect(origin: .zero, size: size), contentX: 0, size: size)
    }

    func animateOutgoing(_ handle: WipeHandle, forward: Bool) {
        let drift = effectiveSize.width * driftFraction
        handle.page.setOutgoingDrift(forward ? -drift : drift)
    }

    /// Settle this incoming page and remove only pages below it. Any later pages
    /// remain above it with their independent animations untouched.
    func finishWipe(_ handle: WipeHandle) {
        let incoming = handle.page
        guard let incomingIndex = pages.firstIndex(where: { $0 === incoming }) else { return }
        let size = effectiveSize
        let full = CGRect(origin: .zero, size: size)
        incoming.setWindow(full, contentX: 0, size: size)
        revealingPages.remove(ObjectIdentifier(incoming))

        for obsolete in pages[..<incomingIndex] {
            revealingPages.remove(ObjectIdentifier(obsolete))
            obsolete.removeFromSuperview()
        }
        pages.removeFirst(incomingIndex)
        for (index, page) in pages.enumerated() {
            page.layer.zPosition = CGFloat(index)
        }
    }

    private func makePage(image: UIImage?) -> SlidePage {
        let page = SlidePage()
        page.bleed = bleed
        page.image = image
        return page
    }
}

/// A single hero "page": a clipping window containing an inner image view. The
/// page's own `frame` is the visible clip window (which the wipe grows); the inner
/// image is positioned so its content maps to a fixed spot in *container* space
/// regardless of the window. It carries a tiny `bleed` overscan on each side only
/// to avoid a sub-pixel seam shimmer while the window animates.
fileprivate final class SlidePage: UIView {
    private let contentView = UIView()
    private let imageView = UIImageView()
    var bleed: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        contentView.addSubview(imageView)
        addSubview(contentView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    /// Set this page's clip `window` (container coords) and position the image so
    /// its logical left edge lands at `contentX` in *container* coords. Both the
    /// page frame and the content wrapper's center are set here; animating a
    /// `setWindow` call interpolates both together, so the content stays correctly
    /// anchored at every frame.
    ///
    /// Outgoing drift uses the wrapper's transform while this uses center/bounds,
    /// avoiding concurrent writes to the same animatable property.
    func setWindow(_ window: CGRect, contentX: CGFloat, size: CGSize) {
        frame = window
        // The image spans [contentX - bleed, contentX + size.width + bleed] in
        // container coords; convert to this page's local coords (subtract origin).
        let contentSize = CGSize(width: size.width + 2 * bleed, height: size.height)
        contentView.bounds = CGRect(origin: .zero, size: contentSize)
        contentView.center = CGPoint(
            x: contentX - bleed - window.origin.x + contentSize.width / 2,
            y: contentSize.height / 2
        )
        imageView.frame = contentView.bounds
    }

    func setOutgoingDrift(_ x: CGFloat) {
        contentView.transform = CGAffineTransform(translationX: x, y: 0)
    }

    func resetOutgoingDrift() {
        contentView.transform = .identity
    }
}
#endif
#endif
