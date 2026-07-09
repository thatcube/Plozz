#if canImport(SwiftUI)
import SwiftUI

/// The shared, full-bleed hero **backdrop** treatment: a wide landscape image
/// with a mode-appropriate legibility scrim and a bottom dissolve that melts the
/// artwork into the app background. This is the single source of truth for the
/// "cinematic hero" look used by both the item **detail** page (`DetailHeroView`)
/// and the Home **hero carousel** (`HomeHeroView`), so the two can never drift.
///
/// It is deliberately *purely visual and layout-neutral*: it renders as the host
/// view's `.background`, ignores the tvOS overscan safe area, and never reports a
/// size that would inflate its parent's layout width — matching how the detail
/// hero hosts its backdrop.
///
/// ### Background-video slot (phased trailer support)
/// The optional `backgroundVideo` view builder overlays the static image and
/// receives the exact same scrim + dissolve + clip treatment, so a muted looping
/// trailer can later be faded in on top of the still without any rework. It is an
/// `EmptyView` by default (today), so the image-only path is byte-for-byte the
/// same as the detail hero's original backdrop.
public struct HeroBackdropLayer<Video: View>: View {
    /// Ordered candidate backdrop URLs (first that loads and is wide enough wins).
    private let urls: [URL]
    /// Last-resort async art lookup (e.g. TMDb fanart) when none of `urls` load.
    private let asyncFallbackURL: (@Sendable () async -> URL?)?
    /// Poster used to synthesise a blurred cinematic wash when there is no real
    /// landscape art at all. `nil` falls back to a neutral fill.
    private let placeholderPosterURL: URL?
    /// The backdrop's rendered height (the caller scales this by any hero-height
    /// fraction / bottom extension before passing it in).
    private let height: CGFloat
    /// Legibility scrim tone — dark in dark mode (for light content), light in
    /// light mode (for dark content). Geometry is identical; only the tone flips.
    private let scrimTone: Color
    /// Blurs the still image (used by spoiler-hiding). Never blurs the video slot.
    private let blursImage: Bool
    /// Fraction of the height at which the bottom dissolve *begins* (the image is
    /// fully opaque above it and fades to transparent by the bottom edge). The
    /// item **detail** hero melts into the page early (`0.33`) because content
    /// scrolls up over it; the **Home** hero fills the screen, so it keeps the
    /// artwork opaque far lower and only feathers the very bottom into the
    /// Continue Watching panel.
    private let dissolveStart: CGFloat
    /// Whether this layer breaks out of the tvOS overscan safe area itself. `true`
    /// (the detail hero + the single-image case) makes it span the physical screen
    /// edge to edge. `false` is used when the caller lays several backdrops side by
    /// side (the Home hero filmstrip): each cell must stay at its exact frame width
    /// so the strip tiles correctly, and the *container* applies the overscan
    /// breakout once for the whole strip.
    private let ignoresOverscan: Bool
    /// Overlaid on the still image; empty today, hosts a faded-in trailer later.
    private let backgroundVideo: () -> Video

    public init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        placeholderPosterURL: URL? = nil,
        height: CGFloat,
        scrimTone: Color,
        blursImage: Bool = false,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true,
        @ViewBuilder backgroundVideo: @escaping () -> Video
    ) {
        self.urls = urls
        self.asyncFallbackURL = asyncFallbackURL
        self.placeholderPosterURL = placeholderPosterURL
        self.height = height
        self.scrimTone = scrimTone
        self.blursImage = blursImage
        self.dissolveStart = dissolveStart
        self.ignoresOverscan = ignoresOverscan
        self.backgroundVideo = backgroundVideo
    }

    public var body: some View {
        FallbackAsyncImage(
            urls: urls,
            maxAspectRatio: 3.0,
            variant: .heroBackdrop,
            asyncFallbackURL: asyncFallbackURL
        ) {
            placeholder
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        // Apply the blur ONLY when actually hiding a spoiler. `.blur(radius: 0)`
        // still forces a full-screen offscreen render pass (a ~33MB 4K RGBA
        // buffer on this panel) every time the modifier is present, even at
        // radius 0 — so on the common non-spoiler path we omit the modifier
        // entirely rather than paying for a no-op blur surface on every hero.
        .modifier(ConditionalBlur(radius: blursImage ? 40 : nil))
        // Trailer slot: overlays the still (and so inherits the scrim + dissolve
        // below). Empty today — no layout or visual effect on the image-only path.
        .overlay { backgroundVideo() }
        .overlay(scrim)
        .mask(dissolveMask)
        // Break out of the tvOS overscan safe area so the backdrop spans the full
        // screen edge to edge — across the top too, otherwise the top overscan
        // inset shows through as a black bar above the artwork. Skipped when the
        // caller tiles several cells (the Home hero filmstrip) and applies the
        // breakout once at the container instead.
        .modifier(OverscanBreakout(enabled: ignoresOverscan))
    }

    /// Legibility scrim: fades a mode-appropriate tone in over the leading side so
    /// the title/logo/overview read clearly against the artwork, while leaving the
    /// right side (the hero subject) clear. Lives *under* the dissolve mask so it
    /// fades away with the image and never tints the revealed background.
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

    /// Dissolves the backdrop's own alpha to transparent over the lower portion
    /// (top third stays a clean image) so the real app background shows straight
    /// through — a perfectly seamless transition with no second colour to mismatch.
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

    /// Fallback when no real wide backdrop exists. We deliberately do **not** blow
    /// the poster up into a blurred wash — the hero is never blurred. A real
    /// backdrop is resolved first through the async fallback chain (which now
    /// includes the bundled TheTVDB fanart tier); this clean, mode-appropriate
    /// ambient gradient shows only when a title genuinely has no landscape art.
    private var placeholder: some View {
        LinearGradient(
            colors: [
                scrimTone.opacity(0.28),
                scrimTone.opacity(0.10)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Applies the tvOS overscan breakout only when `enabled`, so the same backdrop
/// view can either span the physical screen (detail hero / single image) or stay
/// within its given frame (a cell in the Home hero filmstrip).
private struct OverscanBreakout: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.ignoresSafeArea(edges: [.top, .horizontal])
        } else {
            content
        }
    }
}

/// Applies `.blur` only when a radius is supplied. A `nil` radius omits the
/// modifier entirely so no offscreen blur buffer is allocated — unlike
/// `.blur(radius: 0)`, which still forces a full-screen offscreen render pass.
private struct ConditionalBlur: ViewModifier {
    let radius: CGFloat?
    func body(content: Content) -> some View {
        if let radius {
            content.blur(radius: radius)
        } else {
            content
        }
    }
}

public extension HeroBackdropLayer where Video == EmptyView {
    /// Image-only backdrop (no trailer slot) — the default today. Byte-for-byte
    /// the same treatment the detail hero has always rendered.
    init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        placeholderPosterURL: URL? = nil,
        height: CGFloat,
        scrimTone: Color,
        blursImage: Bool = false,
        dissolveStart: CGFloat = 0.33,
        ignoresOverscan: Bool = true
    ) {
        self.init(
            urls: urls,
            asyncFallbackURL: asyncFallbackURL,
            placeholderPosterURL: placeholderPosterURL,
            height: height,
            scrimTone: scrimTone,
            blursImage: blursImage,
            dissolveStart: dissolveStart,
            ignoresOverscan: ignoresOverscan,
            backgroundVideo: { EmptyView() }
        )
    }
}
#endif
