import Foundation

/// The origin of an external rating. Provider-agnostic: any backend or
/// enrichment service maps its native sources onto these cases.
public enum RatingSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// IMDb user rating (0–10).
    case imdb
    /// Rotten Tomatoes "Tomatometer" critic score (percentage).
    case rottenTomatoes
    /// Rotten Tomatoes "Audience Score" (percentage).
    case rottenTomatoesAudience
    /// Metacritic Metascore (0–100).
    case metacritic
    /// Letterboxd average rating (0–5). No public API yet — reserved so the UI
    /// already supports it if a provider is added later.
    case letterboxd
    /// The Movie Database user rating (0–10).
    case tmdb
    /// A backend's generic "community"/audience rating (e.g. Jellyfin
    /// `CommunityRating`, 0–10) when the upstream source is unspecified.
    case community
    /// A backend's generic critic rating when the upstream source is
    /// unspecified.
    case critic

    /// Human-readable label for the badge.
    public var displayName: String {
        switch self {
        case .imdb: return "IMDb"
        case .rottenTomatoes: return "Rotten Tomatoes"
        case .rottenTomatoesAudience: return "RT Audience"
        case .metacritic: return "Metacritic"
        case .letterboxd: return "Letterboxd"
        case .tmdb: return "TMDB"
        case .community: return "Community"
        case .critic: return "Critics"
        }
    }

    /// Stable ordering for consistent UI layout (lower sorts first).
    public var sortRank: Int {
        switch self {
        case .imdb: return 0
        case .rottenTomatoes: return 1
        case .rottenTomatoesAudience: return 2
        case .metacritic: return 3
        case .letterboxd: return 4
        case .tmdb: return 5
        case .community: return 6
        case .critic: return 7
        }
    }
}

/// The native scale a raw rating value is expressed in.
public enum RatingScale: String, Codable, Sendable, Hashable {
    /// 0...10 (IMDb/TMDB-style).
    case outOfTen
    /// 0...100 (Metacritic-style).
    case outOfHundred
    /// 0...100, rendered as a percentage (Rotten Tomatoes-style).
    case percent
    /// 0...5 (Letterboxd-style).
    case outOfFive

    /// The maximum value this scale can take.
    public var maximum: Double {
        switch self {
        case .outOfTen: return 10
        case .outOfHundred, .percent: return 100
        case .outOfFive: return 5
        }
    }
}

/// A single rating from an external/critical source, in its native scale.
///
/// Stored in the source's own units (so `displayValue` looks familiar) with a
/// `normalized` 0...1 accessor for cross-source comparison or progress UI.
public struct ExternalRating: Codable, Hashable, Sendable, Identifiable {
    public var source: RatingSource
    /// The raw score in `scale`'s units (e.g. `8.8`, `74`).
    public var value: Double
    public var scale: RatingScale

    public var id: RatingSource { source }

    public init(source: RatingSource, value: Double, scale: RatingScale) {
        self.source = source
        self.value = value
        self.scale = scale
    }

    /// The score normalized to `0...1`, clamped.
    public var normalized: Double {
        guard scale.maximum > 0 else { return 0 }
        return min(max(value / scale.maximum, 0), 1)
    }

    /// A familiar, source-appropriate display string (e.g. `8.8`, `74%`,
    /// `74/100`, `4.1/5`).
    public var displayValue: String {
        switch scale {
        case .outOfTen:
            return Self.trimmed(value)
        case .percent:
            return "\(Int(value.rounded()))%"
        case .outOfHundred:
            return "\(Int(value.rounded()))/100"
        case .outOfFive:
            return "\(Self.trimmed(value))/5"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

public extension ExternalRating {
    /// Parses an OMDb `Ratings` entry value string into an `ExternalRating`.
    ///
    /// OMDb reports values like `"8.8/10"`, `"74%"`, or `"74/100"`. Returns
    /// `nil` when the string can't be parsed.
    static func parseOMDb(source: RatingSource, value rawValue: String) -> ExternalRating? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasSuffix("%") {
            let numberPart = trimmed.dropLast()
            guard let number = Double(numberPart) else { return nil }
            return ExternalRating(source: source, value: number, scale: .percent)
        }

        if let slashIndex = trimmed.firstIndex(of: "/") {
            let numberPart = trimmed[trimmed.startIndex..<slashIndex]
            let denomPart = trimmed[trimmed.index(after: slashIndex)...]
            guard let number = Double(numberPart.trimmingCharacters(in: .whitespaces)),
                  let denom = Double(denomPart.trimmingCharacters(in: .whitespaces))
            else { return nil }
            let scale: RatingScale = denom >= 100 ? .outOfHundred : .outOfTen
            return ExternalRating(source: source, value: number, scale: scale)
        }

        guard let number = Double(trimmed) else { return nil }
        return ExternalRating(source: source, value: number, scale: .outOfTen)
    }
}

public extension Array where Element == ExternalRating {
    /// Merges `authoritative` ratings over `self`, keeping one entry per source.
    /// Authoritative entries (e.g. from a dedicated ratings API) replace any
    /// existing entry of the same source. Result is ordered by `sortRank`.
    func mergedWithAuthoritative(_ authoritative: [ExternalRating]) -> [ExternalRating] {
        var bySource: [RatingSource: ExternalRating] = [:]
        for rating in self { bySource[rating.source] = rating }
        for rating in authoritative { bySource[rating.source] = rating }
        return bySource.values.sorted { $0.source.sortRank < $1.source.sortRank }
    }
}
