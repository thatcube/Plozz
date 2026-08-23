#if canImport(SwiftUI)
import SwiftUI

/// How a Continue Watching card identifies itself.
///
/// A two-way *choice*, not an on/off: both states put artwork on the card, so any
/// switch label would imply that turning it off leaves the card blank.
public enum ContinueWatchingArtworkStyle: String, CaseIterable, Sendable {
    /// Artwork with the title laid over it as a logo, and nothing written below:
    /// the episode or year rides in the resume chip, on the artwork.
    case logoAndArtwork
    /// Plain artwork, with the title *and* its details — the episode designation,
    /// or a movie's year — written on two lines underneath. Masked to match the
    /// spoiler settings.
    case thumbnail

    public var displayName: LocalizedStringResource {
        switch self {
        case .logoAndArtwork:
            return LocalizedStringResource(
                "continueWatchingArtwork.logoAndArtwork",
                defaultValue: "Logo & Artwork",
                comment: "Continue Watching card style option in Settings: artwork with the title laid over it as a logo."
            )
        case .thumbnail:
            return LocalizedStringResource(
                "continueWatchingArtwork.thumbnailAndTitle",
                defaultValue: "Thumbnail & Title",
                comment: "Continue Watching card style option in Settings: plain artwork with the title written underneath."
            )
        }
    }

    public var detail: LocalizedStringResource {
        switch self {
        case .logoAndArtwork:
            return LocalizedStringResource(
                "continueWatchingArtwork.logoAndArtwork.detail",
                defaultValue: "Title and details on the artwork.",
                comment: "One-line explanation of the Logo & Artwork option for Continue Watching cards."
            )
        case .thumbnail:
            return LocalizedStringResource(
                "continueWatchingArtwork.thumbnailAndTitle.detail",
                defaultValue: "Title and details below the artwork.",
                comment: "One-line explanation of the Thumbnail & Title option for Continue Watching cards."
            )
        }
    }
}

/// A picture of one Continue Watching card in each
/// ``ContinueWatchingArtworkStyle``.
///
/// Each leans on the one thing that actually tells them apart: where the title
/// lives. Both options put artwork on the card, so the previews show the title
/// set into the artwork as a wordmark, or written on a line beneath it.
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
            let available = height - captionHeight - gap - bottomInset
            // The two options are now different SHAPES — the logo card is taller,
            // because it reserves a band under its picture for the chrome. Size
            // both from one shared width (so the pair still reads as one scale,
            // not two zoom levels) and from what the TALLER of them can fit.
            let cardWidth = min(
                width * 0.94,
                available * ContinueWatchingCardShape.aspectRatio
            )
            let cardHeight = cardWidth / cardAspectRatio
            VStack(spacing: gap) {
                card(width: cardWidth, height: cardHeight)
                caption(width: cardWidth, barHeight: barHeight, spacing: height * 0.025)
                    .opacity(style == .thumbnail ? 1 : 0)
            }
            .frame(width: width, height: height, alignment: .center)
        }
    }

    /// The logo option stands taller than its 16:9 picture; the thumbnail option
    /// is the picture and nothing else.
    private var cardAspectRatio: CGFloat {
        switch style {
        case .logoAndArtwork: return ContinueWatchingCardShape.aspectRatio
        case .thumbnail: return 16.0 / 9.0
        }
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        let radius = min(cornerRadius, width * 0.06)
        return ZStack {
            artwork(width: width, height: height)
            if style == .logoAndArtwork {
                wordmark(width: width)
                    // Centred on the PICTURE, matching the real card: the band
                    // beneath it belongs to the chrome.
                    .offset(y: -height * (1 - ContinueWatchingCardShape.mirrorLine) / 2)
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

    /// The word itself, rather than an invented title: a plausible one is read as
    /// *that* title's logo and leaves you wondering what it is, where "LOGO" is
    /// instantly understood as "whatever your logo is". Still lettering, which is
    /// the one unmistakable way to draw "a logo sits here".
    private static let logoPlaceholder = LocalizedStringResource(
        "continueWatchingArtwork.logoPlaceholder",
        defaultValue: "LOGO",
        comment: "Stand-in wordmark drawn inside the Continue Watching card preview, in place of a real title's logo."
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
        case .logoAndArtwork:
            // Drawn through the real card's own fill, so the preview can't drift
            // from what the card actually does — including the mirrored band that
            // carries the chrome.
            ExtendedArtworkFill(
                picture: ZStack {
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
            )
        case .thumbnail:
            ZStack {
                // A dusk horizon. A landscape reads as a *photograph of
                // somewhere* at any size, which is the whole point of this
                // option — a frame out of what you're watching, not branding. A figure
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
    /// the choice is about. The logo card's scrim runs from high in the picture
    /// and finishes lighter, matching the real card.
    private func chip(width: CGFloat, height: CGFloat) -> some View {
        let isLogo = style == .logoAndArtwork
        let scrimHeight = isLogo
            ? height * (1 - ContinueWatchingCardShape.scrimStart)
            : height * 0.40
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, .black.opacity(isLogo ? ContinueWatchingCardShape.scrimDepth : 0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: scrimHeight)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: width * 0.022) {
                    PlayGlyph()
                        .fill(.white)
                        .frame(width: width * 0.056, height: width * 0.067)
                    Capsule()
                        .fill(.white.opacity(0.45))
                        .frame(width: width * 0.19, height: width * 0.025)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: width * 0.19 * 0.42, height: width * 0.025)
                        }
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: width * 0.20, height: width * 0.028)
                }
                .padding(.leading, width * 0.05)
                .padding(.bottom, width * 0.042)
            }
        }
    }

    /// The two caption lines under the card — the title, then its details — which
    /// only the thumbnail option has. With the logo on the artwork there is
    /// nothing left for a caption to say.
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
