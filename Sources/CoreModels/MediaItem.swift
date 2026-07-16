import Foundation

/// A kind of playable/browsable media item, provider-agnostic.
public enum MediaItemKind: String, Codable, Sendable {
    case movie
    case series
    case season
    case episode
    case video
    case folder
    case collection
    case unknown
}

/// Library-availability of a title, independent of any single provider.
///
/// Mirrors Overseerr/Jellyseerr's `MediaStatus` enum (raw values are wire-stable
/// with that API) so a Seerr-sourced **featured** item can carry whether it's
/// already in the library, in-flight, or requestable. `nil` on a `MediaItem`
/// means "not applicable / unknown" (e.g. an ordinary library item that never
/// came from Seerr). Used to pick the right hero CTA — Request vs. Pending vs.
/// Available — without the UI importing the Seerr module.
public enum MediaAvailabilityStatus: Int, Codable, Sendable, Equatable, CaseIterable {
    /// Never requested / not tracked by the discovery backend.
    case unknown = 1
    /// A request exists and is awaiting approval.
    case pending = 2
    /// Approved and handed to Radarr/Sonarr (downloading).
    case processing = 3
    /// Some seasons (TV) or parts are available.
    case partiallyAvailable = 4
    /// Fully available to stream in the library.
    case available = 5
    /// Was available, since removed.
    case deleted = 6

    /// Whether a one-tap "Request" makes sense for this state (nothing is in
    /// flight or already available).
    public var isRequestable: Bool {
        switch self {
        case .unknown, .deleted: return true
        case .pending, .processing, .partiallyAvailable, .available: return false
        }
    }
}

/// A provider-agnostic cast/crew member shown on a detail page. For anime the
/// `Actor` entries are the voice cast, with `role` holding the voiced character.
public struct MediaPerson: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The character played/voiced, when the provider reports one (actors only).
    public var role: String?
    /// Provider-native role kind, e.g. `Actor`, `GuestStar`, `Director`,
    /// `Writer`, `Producer`. Used to separate cast from crew in the UI.
    public var kind: String?
    /// Headshot artwork, when the person has an image on the server.
    public var imageURL: URL?

    public init(
        id: String,
        name: String,
        role: String? = nil,
        kind: String? = nil,
        imageURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.kind = kind
        self.imageURL = imageURL
    }

    /// True for on-screen/voice talent (vs. crew), used to build the "Cast" row.
    public var isCast: Bool {
        switch kind?.lowercased() {
        case "actor", "gueststar", nil: return true
        default: return false
        }
    }
}

/// A provider-agnostic media item.
///
/// Providers map their native item shapes (Jellyfin `BaseItemDto`, later Plex
/// `Metadata`) onto this type so feature code never imports a provider module.
public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The title in the work's original/production language, when the server
    /// records one distinct from the (often localised) display `title`. Foreign
    /// films routinely carry e.g. a Spanish display title with the original
    /// English title here. Used as an extra cross-server discovery query so a
    /// title named differently on each server is still found and matched by id.
    public var originalTitle: String?
    public var kind: MediaItemKind
    public var overview: String?

    /// Series title for an episode, etc.
    public var parentTitle: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var productionYear: Int?

    /// The content/age-classification certificate, e.g. `TV-14`, `PG-13`, `R`.
    /// Provider-native string (Jellyfin `OfficialRating`); `nil` when unrated or
    /// unreported. Rendered as an outlined badge on the detail hero.
    public var officialRating: String?

    /// Genre labels for the item, e.g. `["Action", "Adventure"]`. Ordered as the
    /// provider returns them; the detail metadata line shows the first few.
    public var genres: [String]

    /// Cast & crew, ordered as the provider returns them (billing order). Only
    /// populated on the detail fetch; empty for items loaded as rows/cards.
    public var people: [MediaPerson]

    /// Production studios (e.g. `MAPPA`, `Wit Studio`). Only populated on the
    /// detail fetch.
    public var studios: [String]

    /// Free-form tags (e.g. `Isekai`, `Shounen`). Only populated on the detail
    /// fetch.
    public var tags: [String]

    /// Short marketing taglines. Only populated on the detail fetch.
    public var taglines: [String]

    /// For an episode, the id of its owning series, enabling a "Go to Series"
    /// jump from anywhere the episode appears. `nil` for non-episodes or when the
    /// provider doesn't report it.
    public var seriesID: String?

    /// For an episode, the id of its owning season, enabling a "Go to Season"
    /// jump (e.g. from a Continue Watching card). `nil` for non-episodes or when
    /// the provider doesn't report it.
    public var seasonID: String?

    /// Total runtime in seconds, if known.
    public var runtime: TimeInterval?
    /// Saved resume position in seconds.
    public var resumePosition: TimeInterval?
    /// Fractional watched progress in `0...1`, if the backend reports it.
    public var playedPercentage: Double?
    public var isPlayed: Bool
    /// Whether this profile has completed the title before, independent of its
    /// current resume/completion state. A Plex rewatch can be both historically
    /// watched and currently in progress; keeping those facts separate lets
    /// recommendation surfaces hide seen media without breaking Resume behavior.
    public var hasBeenPlayed: Bool

    /// Primary (poster) artwork.
    public var posterURL: URL?
    /// The owning series' vertical poster, for episodes. Lets episode cards shown
    /// in a poster grid (Home "Recently Added", library) display the show poster
    /// instead of the episode's own 16:9 still. `nil` for non-episodes.
    public var seriesPosterURL: URL?
    /// Wide/backdrop artwork.
    public var backdropURL: URL?
    /// A higher-resolution backdrop sized for the full-bleed detail hero. Cards
    /// keep using `backdropURL` (a smaller, rail-friendly size); only the hero
    /// reaches for this. `nil` falls back to `backdropURL`.
    public var heroBackdropURL: URL?
    /// Spoiler-safe parent artwork to use when this item has no image of its own
    /// (e.g. an episode with no thumbnail falls back to its series' backdrop).
    /// Never an episode's own frame, so it is safe to show even under spoilers.
    public var fallbackArtworkURL: URL?
    /// Stylized title/logo art (a transparent "clearLogo" PNG) for the detail
    /// hero. For episodes/seasons this is the owning series' logo. `nil` when the
    /// provider has no logo; callers then fall back to TMDb or plain text.
    public var logoURL: URL?

    /// External/critical ratings (IMDb, Rotten Tomatoes, …), in their native
    /// scales. May be enriched asynchronously after the item first loads.
    public var ratings: [ExternalRating]

    /// External database identifiers (e.g. `["Imdb": "tt0111161", "Tmdb": "278"]`),
    /// used by enrichment services to look up additional ratings/metadata.
    public var providerIDs: [String: String]
    /// Field-level origin and optional attribution URL for metadata values.
    public var metadataProvenance: MetadataProvenance

    /// Library-availability of this title as reported by a discovery backend
    /// (Seerr/Overseerr's `mediaInfo.status`). `nil` for ordinary library items
    /// that never came from discovery. Lets the hero pick Request vs. Pending vs.
    /// Available for a **featured** item without importing the Seerr module.
    public var availability: MediaAvailabilityStatus?

    /// Aggregate download progress (`0..<1`) for a not-yet-available **featured**
    /// title currently being fetched by the discovery backend's downloaders
    /// (Seerr → Radarr/Sonarr queue), or `nil` when nothing is downloading. Lets
    /// the hero draw a live progress bar for a requested title without importing
    /// the Seerr module. Transient/live — not part of a title's identity.
    public var downloadProgress: Double?

    /// Source-of-truth technical facts about the underlying file (resolution,
    /// HDR/Dolby Vision range, audio codec/channels, …) when the provider reports
    /// them on the detail fetch. Powers the "4K · Dolby Vision · Dolby Atmos"
    /// technical badge row on the detail hero. `nil` for items fetched without
    /// stream metadata (e.g. rows/cards) and for containers (series/season) that
    /// have no single media file.
    public var mediaInfo: MediaSourceMetadata?

    /// The `Account.id` this item was fetched from, stamped by the Home/Search
    /// aggregator when content from several providers is merged into one row.
    ///
    /// Providers never set this (they don't know app account ids) — it is `nil`
    /// for items returned directly by a single provider and only populated at the
    /// aggregated entry points, so callers can route a tapped item back to its
    /// owning provider. Once you drill into a single-provider subtree the field
    /// is irrelevant and may be `nil`.
    public var sourceAccountID: String?

    /// Other `Account.id`s that also hold this same title, populated when the
    /// Search aggregator de-duplicates a result that exists on several servers
    /// (e.g. the same movie on both a Jellyfin and a Plex account). The primary
    /// source stays in `sourceAccountID`; these are fallbacks so playback can
    /// still resolve the item if the primary server is unavailable. Empty for
    /// non-merged items.
    public var additionalSourceAccountIDs: [String]

    /// The owning library's **provider-local** id on `sourceAccountID`'s server
    /// (matches `MediaLibrary.id`), stamped by the provider/aggregator so Home
    /// can suppress an item when the user hides its library. Combined with
    /// `sourceAccountID` it yields the `AggregatedLibrary.key`
    /// (`"accountID:libraryID"`) the visibility model is keyed on.
    ///
    /// `nil` when the provider/endpoint didn't report it (older cached items,
    /// un-attributed feeds). Home-visibility filtering treats `nil` as
    /// **fail-open** — an item whose library can't be determined stays visible.
    /// For merged cross-server cards each server's own library lives on its
    /// `MediaSourceRef.libraryID`; this field holds the primary source's.
    public var libraryID: String?

    /// Every account this item can be played from, primary first. Derived from
    /// the richer `sources` when the cross-server merge populated them (so the
    /// order matches the server picker), falling back to the legacy
    /// `sourceAccountID` + `additionalSourceAccountIDs` for un-merged items and
    /// older cached JSON.
    public var allSourceAccountIDs: [String] {
        if !sources.isEmpty {
            var seen = Set<String>()
            return sources.compactMap { seen.insert($0.accountID).inserted ? $0.accountID : nil }
        }
        return (sourceAccountID.map { [$0] } ?? []) + additionalSourceAccountIDs
    }

    /// The selectable media sources ("versions") for this title — e.g. a 4K HDR
    /// remux beside a 1080p web-dl. Populated **only** on the detail fetch (rows
    /// and cards leave it empty); zero or one entry means there's nothing to
    /// choose, so no picker is shown. Encoded with a back-compatible default so
    /// older cached `MediaItem` JSON (written before versions existed) still
    /// decodes.
    public var versions: [MediaVersion]

    /// Whether the user has favourited / watchlisted this item on its server
    /// (Jellyfin `UserData.IsFavorite`). Drives the add-vs-remove choice for the
    /// Watchlist action and the Home Watchlist row. Back-compatible default
    /// `false` for older cached JSON.
    public var isFavorite: Bool

    /// The media-source id the user picked in the version picker, threaded into
    /// playback so `Play` targets the chosen file. **Transient UI state** — it is
    /// deliberately excluded from `Codable`/persistence (it's a per-play choice,
    /// not a property of the title) but kept in `Equatable`/`Hashable` so a
    /// re-stamped item triggers a fresh play request. `nil` means "use the
    /// provider/server default source".
    public var selectedVersionID: String?

    /// Every server that holds this same title, captured by the cross-server
    /// merge (``MediaItemMerger``). Primary source first (it backs this card's
    /// id/artwork), then the de-duplicated alternates. Each ref carries **that
    /// server's** own item id, versions and watch-state, so playback, the server
    /// picker, watch-state fan-out and the unified-state fold can address the
    /// right file on the right server. Empty for non-merged items (a single
    /// server's own result), so it never bloats ordinary rows. Encoded with a
    /// back-compatible default so older cached JSON still decodes.
    public var sources: [MediaSourceRef]

    /// When the title was last played on the source server, used as the
    /// most-recent-wins tiebreaker when folding watch-state across servers (and
    /// to order Continue Watching). `nil` when the provider doesn't report it.
    public var lastPlayedAt: Date?

    /// The account/server the user picked in the **server picker** for this play,
    /// threaded into playback so `Play` targets the chosen server's copy.
    /// **Transient UI state** — like `selectedVersionID` it is excluded from
    /// `Codable`/persistence (it's a per-play choice, not a property of the
    /// title) but kept in `Equatable`/`Hashable` so a re-stamped item triggers a
    /// fresh play request. `nil` means "use the primary source".
    public var selectedSourceAccountID: String?

    /// Whether ``selectedSourceAccountID`` reflects a **deliberate user choice**
    /// (the server picker, or a version pick that names its own server) rather
    /// than an auto-computed default. **Transient UI state** — excluded from
    /// `Codable` like the other per-play selections, but kept in
    /// `Equatable`/`Hashable`.
    ///
    /// The best-source play router (`bestSourcePlayItem`) uses this to decide
    /// whether it may re-select a better (more-local) server using *live*
    /// locality: an explicit pick is always honored, but an auto-default is
    /// re-evaluated against the reachable-right-now locality so a title opened
    /// from a remote/Tailscale library still plays from a same-LAN copy when one
    /// exists. `false` for every non-picked item (Home / Search / auto default).
    public var explicitSourceSelection: Bool
    public init(
        id: String,
        title: String,
        originalTitle: String? = nil,
        kind: MediaItemKind,
        overview: String? = nil,
        parentTitle: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        productionYear: Int? = nil,
        officialRating: String? = nil,
        genres: [String] = [],
        people: [MediaPerson] = [],
        studios: [String] = [],
        tags: [String] = [],
        taglines: [String] = [],
        seriesID: String? = nil,
        seasonID: String? = nil,
        runtime: TimeInterval? = nil,
        resumePosition: TimeInterval? = nil,
        playedPercentage: Double? = nil,
        isPlayed: Bool = false,
        hasBeenPlayed: Bool? = nil,
        posterURL: URL? = nil,
        seriesPosterURL: URL? = nil,
        backdropURL: URL? = nil,
        heroBackdropURL: URL? = nil,
        fallbackArtworkURL: URL? = nil,
        logoURL: URL? = nil,
        ratings: [ExternalRating] = [],
        providerIDs: [String: String] = [:],
        metadataProvenance: MetadataProvenance = MetadataProvenance(),
        availability: MediaAvailabilityStatus? = nil,
        downloadProgress: Double? = nil,
        mediaInfo: MediaSourceMetadata? = nil,
        sourceAccountID: String? = nil,
        additionalSourceAccountIDs: [String] = [],
        libraryID: String? = nil,
        versions: [MediaVersion] = [],
        isFavorite: Bool = false,
        selectedVersionID: String? = nil,
        sources: [MediaSourceRef] = [],
        lastPlayedAt: Date? = nil,
        selectedSourceAccountID: String? = nil,
        explicitSourceSelection: Bool = false
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.kind = kind
        self.overview = overview
        self.parentTitle = parentTitle
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.productionYear = productionYear
        self.officialRating = officialRating
        self.genres = genres
        self.people = people
        self.studios = studios
        self.tags = tags
        self.taglines = taglines
        self.seriesID = seriesID
        self.seasonID = seasonID
        self.runtime = runtime
        self.resumePosition = resumePosition
        self.playedPercentage = playedPercentage
        self.isPlayed = isPlayed
        self.hasBeenPlayed = hasBeenPlayed ?? isPlayed
        self.posterURL = posterURL
        self.seriesPosterURL = seriesPosterURL
        self.backdropURL = backdropURL
        self.heroBackdropURL = heroBackdropURL
        self.fallbackArtworkURL = fallbackArtworkURL
        self.logoURL = logoURL
        self.ratings = ratings
        self.providerIDs = providerIDs
        self.metadataProvenance = metadataProvenance
        self.availability = availability
        self.downloadProgress = downloadProgress
        self.mediaInfo = mediaInfo
        self.sourceAccountID = sourceAccountID
        self.additionalSourceAccountIDs = additionalSourceAccountIDs
        self.libraryID = libraryID
        self.versions = versions
        self.isFavorite = isFavorite
        self.selectedVersionID = selectedVersionID
        self.sources = sources
        self.lastPlayedAt = lastPlayedAt
        self.selectedSourceAccountID = selectedSourceAccountID
        self.explicitSourceSelection = explicitSourceSelection
    }

    /// Persisted keys. `selectedVersionID` is intentionally omitted so it is
    /// never encoded or decoded — it is transient per-play UI state, not a fact
    /// about the title. Listing the keys explicitly keeps `Encodable` synthesis
    /// in sync with the custom `init(from:)` below.
    private enum CodingKeys: String, CodingKey {
        case id, title, kind, overview, parentTitle, seasonNumber, episodeNumber
        case originalTitle
        case productionYear, officialRating, genres, people, studios, tags, taglines
        case seriesID, seasonID, runtime, resumePosition, playedPercentage, isPlayed, hasBeenPlayed
        case posterURL, seriesPosterURL, backdropURL, heroBackdropURL
        case fallbackArtworkURL, logoURL, ratings, providerIDs, metadataProvenance, mediaInfo
        case availability
        case downloadProgress
        case sourceAccountID, additionalSourceAccountIDs, versions, isFavorite
        case sources, lastPlayedAt, libraryID
    }

    /// Custom decoding so `additionalSourceAccountIDs` (added after items were
    /// first persisted/cached) defaults to empty when absent, keeping older
    /// encoded `MediaItem`s decodable. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        parentTitle = try container.decodeIfPresent(String.self, forKey: .parentTitle)
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        officialRating = try container.decodeIfPresent(String.self, forKey: .officialRating)
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        people = try container.decodeIfPresent([MediaPerson].self, forKey: .people) ?? []
        studios = try container.decodeIfPresent([String].self, forKey: .studios) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        taglines = try container.decodeIfPresent([String].self, forKey: .taglines) ?? []
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
        seasonID = try container.decodeIfPresent(String.self, forKey: .seasonID)
        runtime = try container.decodeIfPresent(TimeInterval.self, forKey: .runtime)
        resumePosition = try container.decodeIfPresent(TimeInterval.self, forKey: .resumePosition)
        playedPercentage = try container.decodeIfPresent(Double.self, forKey: .playedPercentage)
        isPlayed = try container.decodeIfPresent(Bool.self, forKey: .isPlayed) ?? false
        hasBeenPlayed = try container.decodeIfPresent(Bool.self, forKey: .hasBeenPlayed) ?? isPlayed
        posterURL = try container.decodeIfPresent(URL.self, forKey: .posterURL)
        seriesPosterURL = try container.decodeIfPresent(URL.self, forKey: .seriesPosterURL)
        backdropURL = try container.decodeIfPresent(URL.self, forKey: .backdropURL)
        heroBackdropURL = try container.decodeIfPresent(URL.self, forKey: .heroBackdropURL)
        fallbackArtworkURL = try container.decodeIfPresent(URL.self, forKey: .fallbackArtworkURL)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        ratings = try container.decodeIfPresent([ExternalRating].self, forKey: .ratings) ?? []
        providerIDs = try container.decodeIfPresent([String: String].self, forKey: .providerIDs) ?? [:]
        metadataProvenance = (try? container.decodeIfPresent(
            MetadataProvenance.self,
            forKey: .metadataProvenance
        )) ?? MetadataProvenance()
        availability = try container.decodeIfPresent(MediaAvailabilityStatus.self, forKey: .availability)
        downloadProgress = try container.decodeIfPresent(Double.self, forKey: .downloadProgress)
        mediaInfo = try container.decodeIfPresent(MediaSourceMetadata.self, forKey: .mediaInfo)
        sourceAccountID = try container.decodeIfPresent(String.self, forKey: .sourceAccountID)
        additionalSourceAccountIDs = try container.decodeIfPresent([String].self, forKey: .additionalSourceAccountIDs) ?? []
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        versions = try container.decodeIfPresent([MediaVersion].self, forKey: .versions) ?? []
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        sources = try container.decodeIfPresent([MediaSourceRef].self, forKey: .sources) ?? []
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        selectedVersionID = nil
        selectedSourceAccountID = nil
        explicitSourceSelection = false
    }

    /// Returns a copy of this item tagged as belonging to `accountID`, used by the
    /// aggregator to stamp merged rows with their owning account.
    public func taggingSource(_ accountID: String) -> MediaItem {
        var copy = self
        copy.sourceAccountID = accountID
        return copy
    }

    /// Returns a copy of this item stamped with the provider-local `libraryID`
    /// it was fetched from, so Home-visibility can map it back to an
    /// `AggregatedLibrary.key`. Providers/aggregators call this when (and only
    /// when) they can positively attribute the owning library; leaving it unset
    /// keeps the item fail-open (always visible).
    public func taggingLibrary(_ libraryID: String?) -> MediaItem {
        guard let libraryID else { return self }
        var copy = self
        copy.libraryID = libraryID
        return copy
    }

    /// The `AggregatedLibrary.key`s (`"accountID:libraryID"`) this item can be
    /// attributed to, used by Home-visibility filtering.
    ///
    /// For a single-server item this is at most one key (its
    /// `sourceAccountID` + `libraryID`). For a merged cross-server card it is the
    /// union over every `MediaSourceRef` that carries a `libraryID`, so the
    /// "visible if ANY contributing library is visible" rule can be applied.
    /// Returns an **empty** set when no library can be determined — callers
    /// treat that as fail-open (visible).
    public var homeVisibilityLibraryKeys: Set<String> {
        var keys = Set<String>()
        for source in sources {
            if let libraryID = source.libraryID {
                keys.insert("\(source.accountID):\(libraryID)")
            }
        }
        if let libraryID, let accountID = sourceAccountID {
            keys.insert("\(accountID):\(libraryID)")
        }
        return keys
    }

    /// Whether this item should appear on Home given `isLibraryVisible`, which is
    /// asked about each `AggregatedLibrary.key` the item belongs to.
    ///
    /// Rules: **fail-open** when the item carries no resolvable library
    /// provenance (empty key set ⇒ visible); otherwise visible when **any** of
    /// its contributing libraries is visible (so a merged card surfacing a hidden
    /// and a visible server still shows).
    public func isVisibleOnHome(isLibraryVisible: (String) -> Bool) -> Bool {
        let keys = homeVisibilityLibraryKeys
        if keys.isEmpty { return true }
        return keys.contains { isLibraryVisible($0) }
    }

    /// Returns a copy of this item with `selectedVersionID` set, so a `Play`
    /// invocation carries the user's chosen version through the existing
    /// `(MediaItem) -> Void` play closure without changing its signature.
    public func selectingVersion(_ versionID: String?) -> MediaItem {
        var copy = self
        copy.selectedVersionID = versionID
        return copy
    }

    /// The currently-selected `MediaVersion`, resolved from `selectedVersionID`,
    /// or `nil` when nothing is explicitly selected (use the server default).
    public var selectedVersion: MediaVersion? {
        guard let selectedVersionID else { return nil }
        return versions.first { $0.id == selectedVersionID }
    }

    /// Whether a version picker should be offered: more than one selectable
    /// source exists.
    public var hasMultipleVersions: Bool { versions.count > 1 }

    /// Whether a **server** picker should be offered: the same title was merged
    /// from more than one distinct server/account.
    public var hasMultipleSources: Bool {
        Set(sources.map(\.accountID)).count > 1
    }

    /// The source ref for a given account id, or `nil` when this title isn't
    /// known on that server.
    public func source(forAccountID accountID: String) -> MediaSourceRef? {
        sources.first { $0.accountID == accountID }
    }

    /// The currently-selected source ref, resolved from `selectedSourceAccountID`
    /// (falling back to the primary source), or `nil` when no `sources` exist.
    public var selectedSource: MediaSourceRef? {
        if let selectedSourceAccountID, let match = source(forAccountID: selectedSourceAccountID) {
            return match
        }
        return sources.first
    }

    /// Returns a copy retargeted to play from `source` (and optionally a specific
    /// version on that server). The returned item's `id`, `sourceAccountID`,
    /// `versions` and watch-state are swapped to the chosen server's copy so the
    /// existing play-routing (`provider(forAccountID:)` → play `item.id` +
    /// `selectedVersionID`) targets the right file on the right server, while
    /// `sources`/identity are preserved for further switching. A no-op-safe
    /// `versionID` that isn't on the target server is dropped (server default).
    public func selectingSource(_ source: MediaSourceRef, versionID: String? = nil, explicit: Bool = false) -> MediaItem {
        var copy = self
        copy.id = source.itemID
        copy.sourceAccountID = source.accountID
        copy.selectedSourceAccountID = source.accountID
        copy.explicitSourceSelection = explicit
        // Keep the current versions when the target source ref carries none:
        // Home / Search source refs are membership-only (versions are populated
        // live by a detail fetch, never on those refs), so overwriting with an
        // empty list here would strip a title's known versions — losing a
        // remembered per-title version preference the next time detail opens.
        if !source.versions.isEmpty {
            copy.versions = source.versions
        }
        copy.resumePosition = source.resumePosition
        copy.playedPercentage = source.playedPercentage
        copy.isPlayed = source.isPlayed
        copy.hasBeenPlayed = source.hasBeenPlayed
        copy.isFavorite = source.isFavorite
        copy.lastPlayedAt = source.lastPlayedAt
        if let versionID, source.versions.contains(where: { $0.id == versionID }) {
            copy.selectedVersionID = versionID
        } else {
            copy.selectedVersionID = nil
        }
        return copy
    }

    /// Builds the retargeted item the player should launch for the supplied
    /// version pick. Centralised here (instead of being private to the view)
    /// so the routing logic is unit-testable without dragging in SwiftUI.
    ///
    /// Routing rules (in priority order):
    ///  1. **Version names its own backing item** (`sourceItemID` +
    ///     `sourceAccountID`): always repoint to that item. If the matching
    ///     `MediaSourceRef` is missing from `sources` (race / snapshot lag),
    ///     synthesise a one-shot ref from the version itself — without this
    ///     fallback the wrong file would silently play.
    ///  2. **Active account has a source ref**: repoint to that server's ref,
    ///     threading the version id through for true multi-version sources.
    ///  3. **Otherwise** just record the version override on the existing item.
    public static func retargetedForPlayback(
        item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?,
        versionID: String?,
        explicit: Bool = false
    ) -> MediaItem {
        let routed = routedForPlayback(item: item, sources: sources, activeAccountID: activeAccountID, versionID: versionID, explicit: explicit)
        // Resume reconciliation: whichever server backs the chosen stream, seek to
        // the cross-server FURTHEST progress so best-source routing can't rewind
        // playback to 0 when the merged card shows progress made on another server.
        return routed.reconcilingPlaybackResume(acrossSources: sources)
    }

    /// Picks the (item id, account, versions) the player should target — the pure
    /// server/version routing, without resume reconciliation (applied by the
    /// caller, ``retargetedForPlayback``).
    private static func routedForPlayback(
        item: MediaItem,
        sources: [MediaSourceRef],
        activeAccountID: String?,
        versionID: String?,
        explicit: Bool
    ) -> MediaItem {
        let version = versionID.flatMap { id in
            sources.flatMap(\.versions).first(where: { $0.id == id })
        }
        if let version,
           let backingID = version.sourceItemID,
           let backingAccountID = version.sourceAccountID {
            if let backingSource = sources.first(where: { $0.accountID == backingAccountID && $0.itemID == backingID }) {
                return item.selectingSource(backingSource, versionID: nil, explicit: explicit)
            }
            let fallback = MediaSourceRef(
                accountID: backingAccountID,
                itemID: backingID,
                versions: [version]
            )
            return item.selectingSource(fallback, versionID: nil, explicit: explicit)
        }
        if let activeAccountID,
           let primary = sources.first(where: { $0.accountID == activeAccountID }) {
            return item.selectingSource(primary, versionID: versionID, explicit: explicit)
        }
        return item.selectingVersion(versionID)
    }

    /// Returns a copy whose `resumePosition` is the cross-server furthest-progress
    /// resume for `sources` (see ``MediaItemMerger/playbackResumePosition(from:)``),
    /// so the routed play item resumes at the unified position regardless of which
    /// server backs it. A no-op when `sources` is empty (a single-server item that
    /// was never merged keeps its own resume).
    func reconcilingPlaybackResume(acrossSources sources: [MediaSourceRef]) -> MediaItem {
        guard !sources.isEmpty else { return self }
        var copy = self
        copy.resumePosition = MediaItemMerger.playbackResumePosition(from: sources)
        return copy
    }

    /// A human-friendly subtitle line, e.g. `S1 · E3` or the production year.
    public var subtitle: String? {
        if let season = seasonNumber, let episode = episodeNumber {
            return "S\(season) · E\(episode)"
        }
        if let parentTitle { return parentTitle }
        if let productionYear { return String(productionYear) }
        return nil
    }

    /// On-screen / voice talent, in billing order (crew filtered out).
    public var cast: [MediaPerson] {
        people.filter(\.isCast)
    }

    /// The first marketing tagline, when present.
    public var tagline: String? {
        taglines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// A browsable library/collection root (Jellyfin "view").
public struct MediaLibrary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: MediaItemKind
    public var imageURL: URL?

    /// Whether this library holds **music** (Plex "artist" sections, Jellyfin
    /// "music" collections). Music has its own dedicated tab, so a music library
    /// never appears on Home — the Home aggregator excludes it — but it is still a
    /// real library the user can enable/disable (disabling also removes it from the
    /// Music tab). Defaults to `false`; each provider sets it when mapping.
    public var isMusic: Bool

    /// The `Account.id` this library was fetched from, stamped by the aggregator
    /// so a tapped library can be browsed against its owning provider. `nil` when
    /// returned directly by a single provider.
    public var sourceAccountID: String?

    /// Other `Account.id`s that expose the *same* library (e.g. a "Movies"
    /// library that exists on both a Plex and a Jellyfin server), populated when
    /// the Home aggregator merges same-identity libraries across servers so a
    /// single tile browses every server's copy. Empty for a single-server
    /// library. The primary stays in `sourceAccountID`.
    public var additionalSourceAccountIDs: [String]

    /// Maps each contributing `Account.id` to **that server's** own container id
    /// for this merged library, so an aggregated browse can page every server's
    /// copy. Always contains the primary (`sourceAccountID` → `id`) once tagged.
    public var sourceContainerIDByAccount: [String: String]

    public init(
        id: String,
        title: String,
        kind: MediaItemKind,
        imageURL: URL? = nil,
        isMusic: Bool = false,
        sourceAccountID: String? = nil,
        additionalSourceAccountIDs: [String] = [],
        sourceContainerIDByAccount: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.imageURL = imageURL
        self.isMusic = isMusic
        self.sourceAccountID = sourceAccountID
        self.additionalSourceAccountIDs = additionalSourceAccountIDs
        self.sourceContainerIDByAccount = sourceContainerIDByAccount
        // Always keep the primary server addressable in the per-account map.
        if let sourceAccountID, self.sourceContainerIDByAccount[sourceAccountID] == nil {
            self.sourceContainerIDByAccount[sourceAccountID] = id
        }
    }

    /// Every account this library can be browsed from, primary first then the
    /// merged alternates in first-seen order. A single entry means there's only
    /// one server, so the aggregated-browse path collapses to a normal browse.
    public var allSourceAccountIDs: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for accountID in (sourceAccountID.map { [$0] } ?? []) + additionalSourceAccountIDs
        where seen.insert(accountID).inserted {
            result.append(accountID)
        }
        return result
    }

    /// This library's own container id on `accountID`, or `nil` when that server
    /// doesn't hold the library. Falls back to `id` for the primary account.
    public func containerID(forSourceAccountID accountID: String) -> String? {
        if let mapped = sourceContainerIDByAccount[accountID] { return mapped }
        if sourceAccountID == accountID { return id }
        return nil
    }

    /// Returns a copy of this library tagged as belonging to `accountID`, also
    /// recording this server's container id in the per-account map so a later
    /// cross-server merge can address it.
    public func taggingSource(_ accountID: String) -> MediaLibrary {
        var copy = self
        copy.sourceAccountID = accountID
        copy.sourceContainerIDByAccount[accountID] = id
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, imageURL, isMusic, sourceAccountID
        case additionalSourceAccountIDs, sourceContainerIDByAccount
    }

    /// Custom decoding so the cross-server fields (added after libraries were
    /// first persisted) default to empty when absent. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        isMusic = try container.decodeIfPresent(Bool.self, forKey: .isMusic) ?? false
        sourceAccountID = try container.decodeIfPresent(String.self, forKey: .sourceAccountID)
        additionalSourceAccountIDs = try container.decodeIfPresent([String].self, forKey: .additionalSourceAccountIDs) ?? []
        sourceContainerIDByAccount = try container.decodeIfPresent([String: String].self, forKey: .sourceContainerIDByAccount) ?? [:]
        if let sourceAccountID, sourceContainerIDByAccount[sourceAccountID] == nil {
            sourceContainerIDByAccount[sourceAccountID] = id
        }
    }
}
