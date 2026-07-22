import CoreModels

/// The source ordering active before provenance was introduced.
///
/// Step 2 deliberately models this as data without changing any preference. Later
/// work can replace the policy while the router and persisted provenance stay stable.
enum CurrentMetadataPriority {
    static let policy = MetadataPriorityPolicy(rules: artworkRules + overviewRules + scheduleRules)

    static func artworkSources(
        for type: ContentType,
        kind: ArtworkKind
    ) -> [MetadataSource] {
        policy.sources(for: field(for: kind), context: artworkContext(type, kind))
    }

    static func overviewSources(for type: ContentType) -> [MetadataSource] {
        policy.sources(for: .overview, context: overviewContext(type))
    }

    private static let artworkRules: [MetadataPriorityRule] = [
        artwork(.anime, .hero, [.tmdb, .anilist, .kitsu]),
        artwork(.anime, .poster, [.anilist, .kitsu, .tmdb]),
        artwork(.anime, .thumbnail, [.tmdb]),
        artwork(.anime, .logo, [.tmdb, .wikidata, .wikipedia]),

        artwork(.tvShow, .hero, [.tvdb, .tmdb, .wikidata, .wikipedia]),
        artwork(.tvShow, .poster, [.tmdb, .tvmaze, .tvdb, .wikidata, .wikipedia]),
        artwork(.tvShow, .thumbnail, [.tmdb, .tvmaze]),
        artwork(.tvShow, .logo, [.tmdb, .wikidata, .wikipedia]),

        artwork(.movie, .hero, [.tvdb, .tmdb, .wikidata, .wikipedia]),
        artwork(.movie, .poster, [.tmdb, .tvdb, .wikidata, .wikipedia]),
        artwork(.movie, .thumbnail, [.tmdb]),
        artwork(.movie, .logo, [.tmdb, .wikidata, .wikipedia]),

        artwork(.unknown, .hero, [.tvdb, .tmdb, .wikidata, .wikipedia]),
        artwork(.unknown, .poster, [.tmdb, .tvdb, .wikidata, .wikipedia]),
        artwork(.unknown, .thumbnail, [.tmdb]),
        artwork(.unknown, .logo, [.tmdb, .wikidata, .wikipedia]),
    ]

    private static let overviewRules: [MetadataPriorityRule] = [
        overview(.anime, [.wikipedia]),
        overview(.movie, [.wikipedia]),
        overview(.tvShow, [.tvmaze]),
        overview(.unknown, [.wikipedia]),
        overview(.music, []),
    ]

    /// Which schedule provider owns a series' next-episode lookup, by content type.
    /// Anime leads with AniList (its `nextAiringEpisode` is exact and keyless); other
    /// TV leads with TheTVDB then TVmaze (TheTVDB is key-gated and inert on keyless
    /// builds, so keyless devices fall straight through to TVmaze). Movies have no
    /// episode schedule.
    private static let scheduleRules: [MetadataPriorityRule] = [
        schedule(.anime, [.anilist, .tvdb, .tvmaze]),
        schedule(.tvShow, [.tvdb, .tvmaze]),
        schedule(.unknown, [.tvdb, .tvmaze]),
        schedule(.movie, []),
    ]

    private static func artwork(
        _ type: ContentType,
        _ kind: ArtworkKind,
        _ sources: [MetadataSource]
    ) -> MetadataPriorityRule {
        MetadataPriorityRule(
            context: artworkContext(type, kind),
            field: field(for: kind),
            sources: sources
        )
    }

    private static func overview(
        _ type: ContentType,
        _ sources: [MetadataSource]
    ) -> MetadataPriorityRule {
        MetadataPriorityRule(
            context: overviewContext(type),
            field: .overview,
            sources: sources
        )
    }

    private static func schedule(
        _ type: ContentType,
        _ sources: [MetadataSource]
    ) -> MetadataPriorityRule {
        MetadataPriorityRule(
            context: MetadataPriorityContext(rawValue: "nextAiringEpisode.\(type.rawValue)"),
            field: .nextAiringEpisode,
            sources: sources
        )
    }

    private static func artworkContext(
        _ type: ContentType,
        _ kind: ArtworkKind
    ) -> MetadataPriorityContext {
        MetadataPriorityContext(rawValue: "artwork.\(type.rawValue).\(kind.rawValue)")
    }

    private static func overviewContext(_ type: ContentType) -> MetadataPriorityContext {
        MetadataPriorityContext(rawValue: "overview.\(type.rawValue)")
    }

    private static func field(for kind: ArtworkKind) -> MetadataField {
        switch kind {
        case .hero: .backdropURL
        case .poster: .posterURL
        case .thumbnail: .episodeThumbnail
        case .logo: .logoURL
        }
    }
}
