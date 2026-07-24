#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontal row of external rating badges (IMDb, Rotten Tomatoes, …) for
/// the item detail screen, sized to sit inline beside the year/runtime facts.
/// Renders nothing when there are no ratings.
public struct RatingsBadgeRow: View {
    private let ratings: [ExternalRating]
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    public init(ratings: [ExternalRating]) {
        self.ratings = ratings
    }

    public var body: some View {
        if !ratings.isEmpty {
            WrappingHStackLayout(
                alignment: alignment,
                spacing: spacing,
                lineSpacing: 8
            ) {
                ForEach(ratings) { rating in
                    RatingBadge(rating: rating)
                }
            }
        }
    }

    private var alignment: WrappingHStackLayout.RowAlignment {
        #if os(iOS)
        return horizontalSizeClass == .compact ? .center : .leading
        #else
        return .leading
        #endif
    }

    private var spacing: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 12 : 14
        #else
        return 18
        #endif
    }
}

/// A single source's rating: a compact branded icon (a filled star for
/// user/community scores, the IMDb / TMDB logo chips, a tomato/popcorn for
/// Rotten Tomatoes, or a coloured Metacritic chip) beside the formatted score.
/// The score itself is rendered in one neutral, uniform-weight style so the row
/// reads as a single line of facts; only the icons carry brand colour.
public struct RatingBadge: View {
    private let rating: ExternalRating
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// One shared type scale + weight for every score, matching the adjacent
    /// year/runtime metadata line so the whole bottom row reads consistently.
    private var valueFont: Font {
        #if os(iOS)
        return .subheadline.weight(.medium)
        #else
        return .system(size: 23, weight: .medium)
        #endif
    }

    private var iconSize: CGFloat {
        #if os(iOS)
        return horizontalSizeClass == .compact ? 18 : 20
        #else
        return 24
        #endif
    }

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        HStack(spacing: 7) {
            icon
            Text(rating.displayValue)
                .font(valueFont)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        // Preserve each icon + score as one indivisible badge. Without this,
        // SwiftUI compresses the numeric text first when several ratings share a
        // row, producing values such as "8…".
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.source.displayName) rating \(rating.displayValue)")
    }

    @ViewBuilder
    private var icon: some View {
        RatingSourceIcon(rating: rating, size: iconSize)
    }
}

/// The branded icon for a rating source, extracted so both the inline
/// ``RatingBadge`` and the larger ``RatingTile`` render an identical logo (a
/// filled star for user/community scores, the IMDb / TMDB logo chips, a
/// tomato/popcorn for Rotten Tomatoes, or a coloured Metacritic chip). `size` is
/// the shared cap height the glyph is laid out against.
public struct RatingSourceIcon: View {
    private let rating: ExternalRating
    private let size: CGFloat

    public init(rating: ExternalRating, size: CGFloat) {
        self.rating = rating
        self.size = size
    }

    public var body: some View {
        switch rating.source.icon {
        case .star:
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(starColor)
        case .imdb:
            Image("IMDbLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.83, height: size * 0.92)
        case .tmdb:
            Image("TMDBPrimaryShortBlue", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: size * 1.75, height: size * 0.75)
        case .tomato:
            emoji("🍅")
        case .popcorn:
            emoji("🍿")
        case .metacritic:
            metacriticChip
        case .critic:
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: size * 0.78, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var starColor: Color {
        rating.source == .anilist ? Self.anilistBlue : Self.starGold
    }

    private func emoji(_ value: String) -> some View {
        Text(value)
            .font(.system(size: size * 0.82))
    }

    private var metacriticChip: some View {
        Text(String(Int(rating.value.rounded())))
            .font(.system(size: size * 0.75, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: size * 1.42, height: size * 1.42)
            .background(metacriticColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var metacriticColor: Color {
        let score = rating.value
        if score >= 61 { return Self.metacriticGreen }
        if score >= 40 { return Self.metacriticYellow }
        return Self.metacriticRed
    }

    static let starGold = Color(red: 0.96, green: 0.77, blue: 0.13)
    static let anilistBlue = Color(red: 0.13, green: 0.62, blue: 1.0)
    static let metacriticGreen = Color(red: 0.40, green: 0.73, blue: 0.27)
    static let metacriticYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let metacriticRed = Color(red: 0.98, green: 0.27, blue: 0.20)
}

/// A single rating presented as a filled tile — a large branded icon, the score
/// at display size, and a quiet subtitle (vote count, or a Rotten-Tomatoes
/// freshness word). Used in the detail page's ratings grid so one or many ratings
/// fill the space legibly instead of a cramped inline row.
public struct RatingTile: View {
    @Environment(\.themePalette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    private let rating: ExternalRating

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        VStack(spacing: valueSpacing) {
            RatingSourceIcon(rating: rating, size: iconSize)
                .frame(height: iconRowHeight)
            Text(rating.displayValue)
                .font(valueFont)
                .monospacedDigit()
                .foregroundStyle(palette.primaryText)
            subtitle
                .frame(height: subtitleRowHeight)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(palette.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(palette.cardBorder, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.source.displayName) \(rating.displayValue)")
    }

    @ViewBuilder
    private var subtitle: some View {
        Text(subtitleText)
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// The cohort — Critics / Audience / Community — so each score is labelled with
    /// *what kind* of rating it is (answering "is IMDb community? is RT critics?"),
    /// with the vote count appended when the source reports one.
    private var subtitleText: String {
        if let count = rating.ratingCountText {
            return "\(cohortLabel) · \(count)"
        }
        return cohortLabel
    }

    private var cohortLabel: String {
        switch rating.cohort {
        case .critics: return "Critics"
        case .audience: return "Audience"
        case .community: return "Community"
        }
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        return 38
        #else
        return horizontalSizeClass == .compact ? 24 : 28
        #endif
    }

    private var iconRowHeight: CGFloat { iconSize * 1.5 }

    private var valueFont: Font {
        #if os(tvOS)
        return .system(size: 40, weight: .semibold)
        #else
        return horizontalSizeClass == .compact
            ? .title2.weight(.semibold)
            : .system(size: 30, weight: .semibold)
        #endif
    }

    private var subtitleFontSize: CGFloat {
        #if os(tvOS)
        return 18
        #else
        return horizontalSizeClass == .compact ? 12 : 14
        #endif
    }

    private var subtitleRowHeight: CGFloat { subtitleFontSize * 1.4 }

    private var valueSpacing: CGFloat {
        #if os(tvOS)
        return 10
        #else
        return 6
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        return 26
        #else
        return horizontalSizeClass == .compact ? 16 : 20
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        return 20
        #else
        return 14
        #endif
    }

    private var cornerRadius: CGFloat {
        #if os(tvOS)
        return 18
        #else
        return 14
        #endif
    }
}

#endif
