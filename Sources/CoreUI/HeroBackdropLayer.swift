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
    /// Overlaid on the still image; empty today, hosts a faded-in trailer later.
    private let backgroundVideo: () -> Video

    public init(
        urls: [URL],
        asyncFallbackURL: (@Sendable () async -> URL?)? = nil,
        placeholderPosterURL: URL? = nil,
        height: CGFloat,
        scrimTone: Color,
        blursImage: Bool = false,
        @ViewBuilder backgroundVideo: @escaping () -> Video
    ) {
        self.urls = urls
        self.asyncFallbackURL = asyncFallbackURL
        self.placeholderPosterURL = placeholderPosterURL
        self.height = height
        self.scrimTone = scrimTone
        self.blursImage = blursImage
        self.backgroundVideo = backgroundVideo
    }

    public var body: some View {
        FallbackAsyncImage(
            urls: urls,
            maxAspectRatio: 3.0,
            asyncFallbackURL: asyncFallbackURL
        ) {
            placeholder
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .blur(radius: blursImage ? 40 : 0)
        // Trailer slot: overlays the still (and so inherits the scrim + dissolve
        // below). Empty today — no layout or visual effect on the image-only path.
        .overlay { backgroundVideo() }
        .overlay(scrim)
        .mask(dissolveMask)
        // Break out of the tvOS overscan safe area so the backdrop spans the full
        // screen edge to edge — across the top too, otherwise the top overscan
        // inset shows through as a black bar above the artwork.
        .ignoresSafeArea(edges: [.top, .horizontal])
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
                .init(color: .white, location: 0.33),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Always-keyless placeholder: blows up the item's own poster into a soft
    /// cinematic wash so a title with only a poster still gets a rich coloured
    /// hero. Falls back to a neutral fill when there is no poster at all.
    @ViewBuilder
    private var placeholder: some View {
        if let poster = placeholderPosterURL {
            AsyncImage(url: poster) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 60)
                        .scaleEffect(1.2)
                        .overlay(Color.black.opacity(0.35))
                default:
                    Rectangle().fill(.tertiary)
                }
            }
        } else {
            Rectangle().fill(.tertiary)
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
        blursImage: Bool = false
    ) {
        self.init(
            urls: urls,
            asyncFallbackURL: asyncFallbackURL,
            placeholderPosterURL: placeholderPosterURL,
            height: height,
            scrimTone: scrimTone,
            blursImage: blursImage,
            backgroundVideo: { EmptyView() }
        )
    }
}
#endif
