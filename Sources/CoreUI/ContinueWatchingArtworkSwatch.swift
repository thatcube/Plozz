#if canImport(SwiftUI)
import SwiftUI

/// How a Continue Watching card identifies itself.
///
/// Deliberately a two-way *choice* rather than an on/off. Both states show
/// artwork — the question is only *which* artwork — so a switch would have to be
/// labelled something like "display artwork", which reads as though turning it
/// off leaves the card blank.
public enum ContinueWatchingArtworkStyle: String, CaseIterable, Sendable {
    /// The show's own wide art with its logo over it.
    case showArtwork
    /// The episode's thumbnail, masked to match the spoiler settings.
    case episodeThumbnail

    public var displayName: LocalizedStringResource {
        switch self {
        case .showArtwork:
            return LocalizedStringResource(
                "continueWatchingArtwork.showArtwork",
                defaultValue: "Show Artwork",
                comment: "Continue Watching card style option in Settings: the show's artwork and logo."
            )
        case .episodeThumbnail:
            return LocalizedStringResource(
                "continueWatchingArtwork.episodeThumbnail",
                defaultValue: "Episode Thumbnail",
                comment: "Continue Watching card style option in Settings: the episode's own still image."
            )
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .showArtwork:
            return LocalizedStringResource(
                "continueWatchingArtwork.showArtwork.detail",
                defaultValue: "Tell your shows apart at a glance",
                comment: "Explains the Show Artwork option for Continue Watching cards."
            )
        case .episodeThumbnail:
            return LocalizedStringResource(
                "continueWatchingArtwork.episodeThumbnail.detail",
                defaultValue: "Follows your spoiler settings",
                comment: "Explains the Episode Thumbnail option for Continue Watching cards."
            )
        }
    }
}

/// A picture of a single Continue Watching card in each
/// ``ContinueWatchingArtworkStyle`` — the show's art with its logo laid over it,
/// or the episode's own frame with the title captioned underneath.
///
/// Fabricated graphic (no real media, network or theme needed), like
/// ``SpoilerModeSwatch`` — the point is the *shape* of each option: where the
/// title sits, and whether anything is written under the card.
public struct ContinueWatchingArtworkSwatch: View {
    private let style: ContinueWatchingArtworkStyle
    private let cornerRadius: CGFloat

    public init(style: ContinueWatchingArtworkStyle, cornerRadius: CGFloat = 12) {
        self.style = style
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // One card, as wide as fits, 16:9 — the shape of the real row.
            let cardWidth = min(width * 0.82, height * 1.55)
            let cardHeight = cardWidth * 9.0 / 16.0
            VStack(spacing: cardHeight * 0.10) {
                card(width: cardWidth, height: cardHeight)
                if style == .episodeThumbnail {
                    caption(width: cardWidth)
                }
            }
            .frame(width: width, height: height, alignment: .center)
        }
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            artwork(width: width, height: height)
            if style == .showArtwork {
                // The logo stand-in: a wordmark-shaped plate, centred, the way the
                // real card composites a show's logo.
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: width * 0.46, height: height * 0.13)
                    .shadow(color: .black.opacity(0.35), radius: height * 0.03, y: height * 0.012)
            }
            chip(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: min(cornerRadius, width * 0.07), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: min(cornerRadius, width * 0.07), style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.3), lineWidth: 1)
        )
    }

    /// Two clearly different pictures, so the options don't look like the same
    /// card twice: broad show fan-art versus a tighter, warmer episode frame.
    @ViewBuilder
    private func artwork(width: CGFloat, height: CGFloat) -> some View {
        switch style {
        case .showArtwork:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.28, blue: 0.55),
                        Color(red: 0.42, green: 0.20, blue: 0.52)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.30), .clear],
                    center: .init(x: 0.24, y: 0.22),
                    startRadius: 0,
                    endRadius: width * 0.55
                )
            }
        case .episodeThumbnail:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.32, blue: 0.18),
                        Color(red: 0.24, green: 0.18, blue: 0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // A suggestion of a figure in frame, so it reads as a photograph
                // of a moment rather than as cover art.
                Ellipse()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: width * 0.26, height: height * 0.52)
                    .offset(x: -width * 0.16, y: height * 0.16)
                RadialGradient(
                    colors: [Color(red: 1.0, green: 0.85, blue: 0.55).opacity(0.55), .clear],
                    center: .init(x: 0.74, y: 0.30),
                    startRadius: 0,
                    endRadius: width * 0.40
                )
            }
        }
    }

    /// The resume chip along the bottom: play glyph, progress, and a text run.
    /// Present in both options — it isn't what the choice is about.
    private func chip(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.42)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: width * 0.022) {
                    Triangle()
                        .fill(.white)
                        .frame(width: height * 0.10, height: height * 0.12)
                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: width * 0.20, height: height * 0.045)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: width * 0.20 * 0.45, height: height * 0.045)
                        }
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: width * 0.22, height: height * 0.055)
                }
                .padding(.leading, width * 0.05)
                .padding(.bottom, height * 0.07)
            }
        }
    }

    /// The title written under the card. Only the thumbnail option has one: with
    /// the show's logo on the artwork there is nothing left for a caption to say.
    private func caption(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Color.primary.opacity(0.30)).frame(width: width * 0.62, height: 5)
            Capsule().fill(Color.primary.opacity(0.16)).frame(width: width * 0.38, height: 5)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A right-pointing play glyph, drawn rather than set in SF Symbols so it keeps
/// its proportions at swatch scale.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
#endif
