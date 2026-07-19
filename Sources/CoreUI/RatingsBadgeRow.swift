#if canImport(SwiftUI)
import SwiftUI
import CoreModels

/// A horizontal row of external rating badges (IMDb, Rotten Tomatoes, …) for
/// the item detail screen. Renders nothing when there are no ratings.
public struct RatingsBadgeRow: View {
    private let ratings: [ExternalRating]

    public init(ratings: [ExternalRating]) {
        self.ratings = ratings
    }

    public var body: some View {
        if !ratings.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                ForEach(ratings) { rating in
                    RatingBadge(rating: rating)
                }
            }
        }
    }
}

/// A single source's rating: a compact branded icon (a filled star for
/// user/community scores, a TMDB logo chip for TMDB, a tomato/popcorn for
/// Rotten Tomatoes, or a coloured Metacritic chip) beside the formatted score.
/// Rotten Tomatoes scores tint red when fresh and green when rotten, mirroring
/// the real badges.
public struct RatingBadge: View {
    private let rating: ExternalRating

    /// Shared type scale so the icon and score line up to a compact cap height.
    private static let valueFont = Font.system(size: 22, weight: .semibold)
    private static let emphasizedValueFont = Font.system(size: 22, weight: .bold)
    private static let iconSize: CGFloat = 24

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                icon
                Text(rating.displayValue)
                    .font(valueFont)
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
            Text(rating.source.shortLabel)
                .font(.system(size: 14, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
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
        switch rating.source.icon {
        case .star:
            Image(systemName: "star.fill")
                .font(.system(size: Self.iconSize * 0.8, weight: .semibold))
                .foregroundStyle(starColor)
        case .imdb:
            imdbBadge
        case .tmdb:
            tmdbBadge
        case .tomato:
            emoji("🍅")
        case .popcorn:
            emoji("🍿")
        case .metacritic:
            metacriticChip
        }
    }

    /// Tint for star-based sources: AniList in its signature blue so it reads as
    /// distinct from a gold IMDb/user star sitting beside it.
    private var starColor: Color {
        rating.source == .anilist ? Self.anilistBlue : Self.starGold
    }

    /// An emoji icon sized to sit on the shared cap height. Emoji ignore
    /// `foregroundStyle`, so they're only scaled, not tinted.
    private func emoji(_ value: String) -> some View {
        Text(value)
            .font(.system(size: Self.iconSize * 0.82))
    }

    /// Metacritic's signature coloured square: green for favourable scores,
    /// yellow for mixed, red for unfavourable.
    private var metacriticChip: some View {
        Text(String(Int(rating.value.rounded())))
            .font(.system(size: 18, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(metacriticColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var tmdbBadge: some View {
        Image("TMDBPrimaryShortBlue")
            .resizable()
            .scaledToFit()
            .frame(width: 42, height: 18)
    }

    /// IMDb's signature yellow "IMDb" pill (a self-contained logo, so it's not
    /// tinted). Sized to the ~2:1 logo aspect ratio at the shared cap height.
    private var imdbBadge: some View {
        Image("IMDbLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 22)
    }

    /// Tint for the score text — fresh/rotten for Rotten Tomatoes-style sources,
    /// primary otherwise.
    private var valueFont: Font {
        switch rating.source {
        case .tmdb, .rottenTomatoes, .critic:
            return Self.emphasizedValueFont
        default:
            return Self.valueFont
        }
    }

    /// Tint for the score text — fresh/rotten for Rotten Tomatoes-style sources,
    /// primary otherwise.
    private var valueColor: Color {
        switch rating.freshness {
        case .fresh: return Self.freshRed
        case .rotten: return Self.rottenGreen
        case .none: return .primary
        }
    }

    private var metacriticColor: Color {
        let score = rating.value
        if score >= 61 { return Self.metacriticGreen }
        if score >= 40 { return Self.metacriticYellow }
        return Self.metacriticRed
    }

    // Brand-ish colours.
    private static let starGold = Color(red: 0.96, green: 0.77, blue: 0.13)
    private static let anilistBlue = Color(red: 0.13, green: 0.62, blue: 1.0)
    private static let freshRed = Color(red: 0.98, green: 0.27, blue: 0.20)
    private static let rottenGreen = Color(red: 0.18, green: 0.70, blue: 0.40)
    private static let metacriticGreen = Color(red: 0.40, green: 0.73, blue: 0.27)
    private static let metacriticYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    private static let metacriticRed = Color(red: 0.98, green: 0.27, blue: 0.20)
}

#endif
