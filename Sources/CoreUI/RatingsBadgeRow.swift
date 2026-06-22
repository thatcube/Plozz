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
            HStack(spacing: 28) {
                ForEach(ratings) { rating in
                    RatingBadge(rating: rating)
                }
            }
        }
    }
}

/// A single source's rating: a branded icon (🍅 tomato for Rotten Tomatoes, 🍿
/// popcorn for its audience score, ⭐️ for user scores, or a coloured Metacritic
/// chip) beside the formatted score. Rotten Tomatoes scores tint red when fresh
/// and green when rotten, mirroring the real badges.
public struct RatingBadge: View {
    private let rating: ExternalRating

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        HStack(spacing: 8) {
            icon
            Text(rating.displayValue)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.source.displayName) rating \(rating.displayValue)")
    }

    /// The leading icon: the source glyph when it has one, a coloured score chip
    /// for Metacritic, otherwise the source wordmark.
    @ViewBuilder
    private var icon: some View {
        if rating.source == .metacritic {
            metacriticChip
        } else if let glyph = rating.source.glyph {
            Text(glyph)
                .font(.title3)
        } else {
            Text(rating.source.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    /// Metacritic's signature coloured square: green for favourable scores,
    /// yellow for mixed, red for unfavourable.
    private var metacriticChip: some View {
        Text(String(Int(rating.value.rounded())))
            .font(.callout)
            .fontWeight(.bold)
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
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

    // Rotten Tomatoes / Metacritic brand-ish colours.
    private static let freshRed = Color(red: 0.98, green: 0.27, blue: 0.20)
    private static let rottenGreen = Color(red: 0.18, green: 0.70, blue: 0.40)
    private static let metacriticGreen = Color(red: 0.40, green: 0.73, blue: 0.27)
    private static let metacriticYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    private static let metacriticRed = Color(red: 0.98, green: 0.27, blue: 0.20)
}

#endif
