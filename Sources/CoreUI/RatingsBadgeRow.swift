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
            HStack(spacing: 22) {
                ForEach(ratings) { rating in
                    RatingBadge(rating: rating)
                }
            }
        }
    }
}

/// A single source's rating: a compact branded icon (a filled star for
/// user/community scores, a tomato/popcorn for Rotten Tomatoes, or a coloured
/// Metacritic chip) beside the formatted score. Rotten Tomatoes scores tint red
/// when fresh and green when rotten, mirroring the real badges.
public struct RatingBadge: View {
    private let rating: ExternalRating

    /// Shared type scale so the icon and score line up to a compact cap height.
    private static let valueFont = Font.system(size: 22, weight: .semibold)
    private static let iconSize: CGFloat = 24

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        HStack(spacing: 7) {
            icon
            Text(rating.displayValue)
                .font(Self.valueFont)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.source.displayName) rating \(rating.displayValue)")
    }

    @ViewBuilder
    private var icon: some View {
        switch rating.source.icon {
        case .star:
            Image(systemName: "star.fill")
                .font(.system(size: Self.iconSize * 0.8, weight: .semibold))
                .foregroundStyle(Self.starGold)
        case .tomato:
            emoji("🍅")
        case .popcorn:
            emoji("🍿")
        case .metacritic:
            metacriticChip
        }
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
    private static let freshRed = Color(red: 0.98, green: 0.27, blue: 0.20)
    private static let rottenGreen = Color(red: 0.18, green: 0.70, blue: 0.40)
    private static let metacriticGreen = Color(red: 0.40, green: 0.73, blue: 0.27)
    private static let metacriticYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    private static let metacriticRed = Color(red: 0.98, green: 0.27, blue: 0.20)
}

#endif
