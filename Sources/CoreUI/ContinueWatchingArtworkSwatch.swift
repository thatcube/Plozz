#if canImport(SwiftUI)
import SwiftUI

/// How a Continue Watching card identifies itself.
///
/// A two-way *choice*, not an on/off: both states put artwork on the card, so any
/// switch label would imply that turning it off leaves the card blank.
public enum ContinueWatchingArtworkStyle: String, CaseIterable, Sendable {
    /// The show's own wide art with its logo over it. Named for the logo because
    /// that is what actually separates the two options — the alternative shows
    /// artwork too, just the episode's own.
    case showArtwork
    /// The episode's thumbnail, masked to match the spoiler settings.
    case episodeThumbnail

    public var displayName: LocalizedStringResource {
        switch self {
        case .showArtwork:
            return LocalizedStringResource(
                "continueWatchingArtwork.logoAndArtwork",
                defaultValue: "Logo & Artwork",
                comment: "Continue Watching card style option in Settings: the show's artwork with its logo over it."
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
                defaultValue: "Easy to tell apart",
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

/// A picture of one Continue Watching card in each
/// ``ContinueWatchingArtworkStyle``.
///
/// Each leans on the one thing that actually tells them apart: the logo. Both
/// options put artwork on the card, so the previews have to show *whose* — a
/// show's own art with its wordmark set into it, or a frame out of the episode
/// with the title written underneath because nothing on the artwork names it.
///
/// Fabricated throughout, like ``SpoilerModeSwatch`` — no media, network or theme.
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
            // Lay the caption out FIRST and give the card what's left, so the two
            // never overflow the slot. Both options reserve the caption strip even
            // though only one draws into it — otherwise the thumbnail card renders
            // smaller and the pair reads as a scale difference rather than a
            // content one.
            let barHeight = max(3, height * 0.03)
            let captionHeight = barHeight * 2 + height * 0.025
            let gap = height * 0.09
            // A little air under the caption so the last bar isn't flush with the
            // slot's edge.
            let bottomInset = height * 0.04
            let cardHeight = min(
                height - captionHeight - gap - bottomInset,
                width * 0.94 * 9.0 / 16.0
            )
            let cardWidth = cardHeight * 16.0 / 9.0
            VStack(spacing: gap) {
                card(width: cardWidth, height: cardHeight)
                caption(width: cardWidth, barHeight: barHeight, spacing: height * 0.025)
                    .opacity(style == .episodeThumbnail ? 1 : 0)
            }
            .frame(width: width, height: height, alignment: .center)
        }
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        let radius = min(cornerRadius, width * 0.06)
        return ZStack {
            artwork(width: width, height: height)
            if style == .showArtwork {
                wordmark(width: width)
            }
            chip(width: width, height: height)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color(white: 0.5).opacity(0.3), lineWidth: 1)
        )
    }

    /// The word itself, rather than an invented show name: a plausible title is
    /// read as *that show's* logo and leaves you wondering which show it is,
    /// where "LOGO" is instantly understood as "whatever your show's logo is".
    /// Still lettering, which is the one unmistakable way to draw "a logo sits
    /// here".
    private static let logoPlaceholder = LocalizedStringResource(
        "continueWatchingArtwork.logoPlaceholder",
        defaultValue: "LOGO",
        comment: "Stand-in wordmark drawn inside the Continue Watching card preview, in place of a real show's logo."
    )

    private func wordmark(width: CGFloat) -> some View {
        Text(Self.logoPlaceholder)
            .font(.system(size: width * 0.10, weight: .black, design: .rounded))
            .tracking(width * 0.012)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .shadow(color: .black.opacity(0.55), radius: width * 0.02, y: width * 0.006)
            .padding(.horizontal, width * 0.08)
    }

    /// Two pictures that read as different *kinds* of image: flat branded fan-art
    /// with the title set into it, versus a photograph of a moment.
    @ViewBuilder
    private func artwork(width: CGFloat, height: CGFloat) -> some View {
        switch style {
        case .showArtwork:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.10, green: 0.20, blue: 0.46),
                        Color(red: 0.38, green: 0.16, blue: 0.48)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // A wide, even glow — poster lighting, not a photograph.
                RadialGradient(
                    colors: [Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.38), .clear],
                    center: .init(x: 0.5, y: 0.42),
                    startRadius: 0,
                    endRadius: width * 0.62
                )
            }
        case .episodeThumbnail:
            ZStack {
                // A dusk horizon. A landscape reads as a *photograph of
                // somewhere* at any size, which is the whole point of this
                // option — a frame out of the episode, not branding. A figure
                // silhouette was tried first and turned into a restroom
                // pictogram once it got this small.
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.17, blue: 0.38),
                        Color(red: 0.52, green: 0.32, blue: 0.42),
                        Color(red: 0.96, green: 0.60, blue: 0.28)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 1.0, green: 0.97, blue: 0.82), Color(red: 1.0, green: 0.80, blue: 0.42)],
                            center: .center,
                            startRadius: 0,
                            endRadius: width * 0.06
                        )
                    )
                    .frame(width: width * 0.11, height: width * 0.11)
                    .offset(x: -width * 0.14, y: -height * 0.02)
                Ellipse()
                    .fill(Color(red: 0.16, green: 0.10, blue: 0.20))
                    .frame(width: width * 0.95, height: height * 0.55)
                    .offset(x: -width * 0.28, y: height * 0.42)
                Ellipse()
                    .fill(Color(red: 0.08, green: 0.05, blue: 0.12))
                    .frame(width: width * 1.0, height: height * 0.48)
                    .offset(x: width * 0.34, y: height * 0.50)
            }
        }
    }

    /// The resume chip along the bottom — present in both, since it isn't what
    /// the choice is about.
    private func chip(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height * 0.40)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: width * 0.022) {
                    PlayGlyph()
                        .fill(.white)
                        .frame(width: height * 0.10, height: height * 0.12)
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(width: width * 0.19, height: height * 0.045)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: width * 0.19 * 0.42, height: height * 0.045)
                        }
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: width * 0.20, height: height * 0.05)
                }
                .padding(.leading, width * 0.05)
                .padding(.bottom, height * 0.075)
            }
        }
    }

    /// The title written under the card — only the thumbnail option has one. With
    /// the show's logo on the artwork there is nothing left for a caption to say.
    private func caption(width: CGFloat, barHeight: CGFloat, spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            Capsule().fill(Color.primary.opacity(0.34))
                .frame(width: width * 0.58, height: barHeight)
            Capsule().fill(Color.primary.opacity(0.17))
                .frame(width: width * 0.34, height: barHeight)
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A right-pointing play glyph, drawn rather than set in SF Symbols so it keeps
/// its proportions at swatch scale.
private struct PlayGlyph: Shape {
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
