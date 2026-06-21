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

/// A single source's rating: source label over the formatted score.
public struct RatingBadge: View {
    private let rating: ExternalRating

    public init(rating: ExternalRating) {
        self.rating = rating
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rating.source.displayName)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(rating.displayValue)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rating.source.displayName) rating \(rating.displayValue)")
    }
}

#endif
