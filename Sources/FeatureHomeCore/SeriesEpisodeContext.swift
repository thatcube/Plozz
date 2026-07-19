import CoreModels
import MetadataKit

/// Series-level context that should be propagated onto episode items so fallback
/// artwork/routing stays accurate without per-focus remapping.
public struct SeriesEpisodeContext: Sendable {
    public let seriesTMDbID: String?
    public let animeIDs: [String: String]
    public let isAnime: Bool

    public init(series: MediaItem) {
        seriesTMDbID = series.providerIDs["Tmdb"]
        animeIDs = series.providerIDs.filter { ContentClassifier.isAnimeProviderIDKey($0.key) }
        isAnime = ContentClassifier.isAnime(series)
    }

    public init(seriesTMDbID: String?, animeIDs: [String: String], isAnime: Bool) {
        self.seriesTMDbID = seriesTMDbID
        self.animeIDs = animeIDs
        self.isAnime = isAnime
    }

    public var isEmpty: Bool {
        (seriesTMDbID?.isEmpty != false) && animeIDs.isEmpty && !isAnime
    }

    /// Stamps this context into each episode:
    ///  * parent TMDb id under `SeriesTmdb` when missing;
    ///  * anime provider ids (AniList/AniDB/MAL/...) when missing;
    ///  * an "Anime" genre marker when the parent series is anime.
    public func stamping(_ episodes: [MediaItem]) -> [MediaItem] {
        guard !isEmpty else { return episodes }
        return episodes.map { episode in
            var copy = episode
            if let seriesTMDbID, !seriesTMDbID.isEmpty, copy.providerIDs["SeriesTmdb"] == nil {
                copy.providerIDs["SeriesTmdb"] = seriesTMDbID
            }
            for (key, value) in animeIDs where copy.providerIDs[key] == nil {
                copy.providerIDs[key] = value
            }
            if isAnime, !copy.genres.contains(where: { $0.lowercased().contains("anime") }) {
                copy.genres.append("Anime")
            }
            return copy
        }
    }
}
