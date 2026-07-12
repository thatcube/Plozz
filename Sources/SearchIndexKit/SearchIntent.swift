import Foundation
import CoreModels

public struct RuntimeConstraint: Equatable, Sendable {
    public let minimumSeconds: TimeInterval?
    public let maximumSeconds: TimeInterval?

    public init(minimumSeconds: TimeInterval? = nil, maximumSeconds: TimeInterval? = nil) {
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
    }
}

public struct LocalSearchIntent: Equatable, Sendable {
    public let kinds: Set<MediaItemKind>
    public let seriesTitle: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?
    public let minimumYear: Int?
    public let maximumYear: Int?
    public let genres: Set<String>
    public let runtime: RuntimeConstraint?

    public init(
        kinds: Set<MediaItemKind> = [],
        seriesTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        minimumYear: Int? = nil,
        maximumYear: Int? = nil,
        genres: Set<String> = [],
        runtime: RuntimeConstraint? = nil
    ) {
        self.kinds = kinds
        self.seriesTitle = seriesTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.minimumYear = minimumYear
        self.maximumYear = maximumYear
        self.genres = genres
        self.runtime = runtime
    }
}

public struct LocalSearchIntentParser: Sendable {
    private static let knownGenres = [
        "action", "adventure", "animation", "anime", "comedy", "crime",
        "documentary", "drama", "family", "fantasy", "history", "horror",
        "music", "mystery", "romance", "science fiction", "sci-fi",
        "thriller", "war", "western"
    ]

    public init() {}

    public func parse(_ query: String, knownSeriesTitles: [String] = []) -> LocalSearchIntent {
        let normalized = SearchDocumentBuilder.normalized(query)
        let kinds = detectedKinds(in: normalized)
        let seriesTitle = knownSeriesTitles
            .sorted { $0.count > $1.count }
            .first { normalized.contains(SearchDocumentBuilder.normalized($0)) }
        let season = captureInt(#"\bseason\s+(\d{1,3})\b"#, in: normalized)
            ?? captureInt(#"\bs(\d{1,2})e\d{1,3}\b"#, in: normalized)
        let episode = captureInt(#"\bepisode\s+(\d{1,4})\b"#, in: normalized)
            ?? captureInt(#"\bs\d{1,2}e(\d{1,3})\b"#, in: normalized)
        let yearBounds = years(in: normalized)
        let genres = Set(Self.knownGenres.compactMap { genre -> String? in
            normalized.contains(genre) ? canonicalGenre(genre) : nil
        })

        return LocalSearchIntent(
            kinds: kinds,
            seriesTitle: seriesTitle,
            seasonNumber: season,
            episodeNumber: episode,
            minimumYear: yearBounds.minimum,
            maximumYear: yearBounds.maximum,
            genres: genres,
            runtime: runtime(in: normalized)
        )
    }

    private func detectedKinds(in query: String) -> Set<MediaItemKind> {
        if query.range(of: #"\bepisode\b"#, options: .regularExpression) != nil {
            return [.episode]
        }
        if query.range(of: #"\b(show|series|tv show)\b"#, options: .regularExpression) != nil {
            return [.series]
        }
        if query.range(of: #"\b(movie|film)\b"#, options: .regularExpression) != nil {
            return [.movie]
        }
        return []
    }

    private func years(in query: String) -> (minimum: Int?, maximum: Int?) {
        if let decade = captureInt(#"\b(19\d|20\d)0s\b"#, in: query) {
            return (decade * 10, decade * 10 + 9)
        }
        if let year = captureInt(#"\b((?:19|20)\d{2})\b"#, in: query) {
            return (year, year)
        }
        return (nil, nil)
    }

    private func runtime(in query: String) -> RuntimeConstraint? {
        if let minutes = captureInt(#"\bunder\s+(\d{2,3})\s+minutes?\b"#, in: query) {
            return RuntimeConstraint(maximumSeconds: TimeInterval(minutes * 60))
        }
        if let hours = captureInt(#"\bunder\s+(\d{1,2})\s+hours?\b"#, in: query) {
            return RuntimeConstraint(maximumSeconds: TimeInterval(hours * 3_600))
        }
        if let minutes = captureInt(#"\bover\s+(\d{2,3})\s+minutes?\b"#, in: query) {
            return RuntimeConstraint(minimumSeconds: TimeInterval(minutes * 60))
        }
        return nil
    }

    private func captureInt(_ pattern: String, in value: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }

    private func canonicalGenre(_ genre: String) -> String {
        genre == "sci-fi" ? "science fiction" : genre
    }
}
