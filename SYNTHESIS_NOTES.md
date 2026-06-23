# Plozz metadata synthesis notes

This branch (`thatcube-bookish-goggles`) is a **focused integration**, not a new
architecture. It takes the chosen winning metadata/artwork design as its base and
grafts two high‑value pieces from two other agents' branches onto it, closes one
acknowledged gap in the winner, keeps everything compiling for tvOS, and leaves
the rest of the winner untouched.

## Winning base (unchanged foundation)

- **Branch/commit:** `thatcube-metadata-architecture-opus` (`6ff5a0a`, "Opus 4.8 B").
- New Foundation‑only **`MetadataKit`** module that ships **no user keys**.
  - Tier 1 keyless per‑IP backbone: AniList + Kitsu (anime), TVmaze (western‑TV
    stills), **Deezer** artist `picture_xl` + **MusicBrainz/Cover Art Archive**
    (music).
  - Tier 2 optional maintainer‑hosted TMDb caching proxy (one server‑side key,
    not BYOK).
  - `ArtworkRouter` actor classifies each item and runs per‑(contentType, kind)
    fallback chains, backed by a persistent `MetadataDiskCache`; decoded bytes
    cached by CoreUI's `ArtworkImageCache`.
- See `METADATA_ARCHITECTURE.md` for the full base design. Nothing in that design
  was removed or rewritten here.

---

## Graft #1 — Music UI wiring (closes the winner's deferred Phase 4 gap)

**Why:** the winner already had `MetadataKit` music providers (Deezer artist hero
+ Cover Art Archive/Deezer album cover) and `ArtworkRouter` music methods
(`artistImageURL`, `albumCoverURL`), but the FeatureMusic views never called
them — the winner explicitly deferred "music view wiring" (Phase 4). This graft
completes it.

**Pattern studied (adapted, not copied):** `thatcube-metadata-architecture-codex-a`
(`9a7cbc7`) `Sources/FeatureMusic/MusicArtworkResolver.swift` /
`MusicArtworkImage.swift`. Codex‑a used a standalone MusicBrainz resolver; here it
is adapted to call the **winner's** `ArtworkRouter` instead, so there is one
provider path and one cache.

**What changed:**
- `Package.swift`: added `MetadataKit` to the `FeatureMusic` target dependencies.
- New `Sources/FeatureMusic/MusicArtworkFallback.swift`: tiny bridge exposing
  `albumCover(title:artist:)`, `artistImage(name:)`, `trackCover(title:album:artist:)`
  factories that each return a best‑effort `@Sendable () async -> URL?` closure
  calling `ArtworkRouter.shared`. Returns `nil` when there's nothing to search by.
- `Sources/FeatureMusic/MusicArtworkImage.swift`: `MusicArtworkImage` and
  `MusicCard` now accept an optional `asyncFallbackURL` closure and render through
  CoreUI's existing **`FallbackAsyncImage`** (which already supported an
  `asyncFallbackURL` parameter and uses `ArtworkImageCache`) instead of a bare
  `AsyncImage`. **Server art is always tried first**; the MetadataKit fallback is
  only invoked when the server ships no usable art.
- Wired fallbacks into: `AlbumCard` (album cover), `ArtistCard` (artist hero),
  `NowPlayingView` (hero = track/album cover, full‑screen background = Deezer
  artist image, Up Next rows = album cover), `MiniPlayerBar` (album cover), and
  the `ArtistDetailView` / `AlbumDetailView` headers in `MusicScreens.swift`.
- `PlaylistDetailView`'s header was intentionally left as server‑only (a playlist
  has no single artist/album to resolve by).

**Caching:** no second cache introduced — resolved URLs use the router's
`MetadataDiskCache`; decoded images use CoreUI's `ArtworkImageCache`.

---

## Graft #2 — ID normalization + Plex GUID ingestion (better matching for all providers)

**Why:** the winner's Plex provider stamped `providerIDs: [:]` on every item, so
Plex items reached the classifier/router with **no external ids** — weakening
anime detection and forcing fuzzy title searches. Bringing in normalized external
ids fixes matching accuracy across every provider.

**Source branch:** `thatcube-metadata-provider-architecture` (`558e9bd`, "Codex B").

**What changed:**
- `Sources/CoreModels/ProviderIDNamespace.swift`: ported **verbatim** (purely
  additive). Adds the `ProviderIDNamespace` enum and `Dictionary`/`MediaItem`
  helpers `providerID(_:)`, `normalizedProviderIDs`, `isLikelyAnime` that resolve
  provider‑id key aliases case/punctuation‑insensitively
  (`Imdb`/`IMDb`/`tmdbid`/`MAL`/…).
- `Sources/ProviderPlex/PlexDTOs.swift`: added the `Guid` array + `PlexGuid` DTO.
- `Sources/ProviderPlex/PlexProvider.swift`: added `providerIDs(from:)` that maps
  Plex `imdb://` / `tmdb://` / `tvdb://` / `anidb://` / `anilist://` /
  `myanimelist://` / `mbid://` GUIDs into the shared `MediaItem.providerIDs`
  shape (Jellyfin‑matching key casing). The item builder now uses it instead of
  `[:]`.
- `Sources/ProviderPlex/PlexClient.swift`: added `includeGuids=1` to the shared
  container query and the single‑item metadata fetch so **list/rail** items (not
  just detail fetches) carry their external GUIDs. (Codex B relied on detail
  fetches only; this additive flag widens coverage.)
- **Integrated the normalized ids into the winner's classifier/router** so they
  are actually consumed:
  - `MetadataKit/ContentClassification.swift`: `ContentClassifier.isAnime` and
    `AnimeIDs(from:)` now resolve AniList/MAL/AniDB via `ProviderIDNamespace`
    (Kitsu/Shoko still matched by normalized‑key substring, genre/tag labels
    preserved).
  - `MetadataKit/MetadataModels.swift`: `MetadataQuery.cacheKey` resolves
    Tmdb/SeriesTmdb/Imdb via the namespace (so two items for the same show share
    one cache entry regardless of key casing).
  - `MetadataKit/TMDbMetadataProvider.swift` and `TVmazeArtworkProvider.swift`:
    Tmdb/SeriesTmdb/Imdb id reads now go through the namespace.

**Jellyfin:** already ingested `BaseItemDto.ProviderIds` into `providerIDs`
(`JellyfinProvider.swift`), so no Jellyfin change was needed.

---

## Adaptations / conflicts / compromises

- **Codex‑a's music resolver was not used directly.** Its standalone MusicBrainz
  actor would have been a second provider/cache path. Instead the UI was wired to
  the winner's `ArtworkRouter`, satisfying "one cache, winner's structure wins".
- **Codex B is a different architecture** (no `MetadataKit`). Only the two
  data‑layer pieces named above were ported; its `ExternalRating`/RatingSource
  changes were **not** needed for compilation and were left out — the winner's
  ratings code is unchanged.
- **Plex top‑level `plex://` guid** is not parsed (it's an internal Plex id, not
  useful for external matching); only the external `Guid` array is ingested,
  matching Codex B's proven implementation.
- Out‑of‑scope items were respected: PosterCardView / DetailHeroView wiring was
  not touched (the winner already wires those); no merge to main, no PR, no
  on‑device install.

## Build status

`xcodegen generate` + tvOS device `xcodebuild` → **BUILD SUCCEEDED** (no new
warnings in any changed file). `swift test` is not runnable in this repo (mpv
xcframeworks are tvOS‑only), so the device build is the authoritative check.

---

## Needs ON‑DEVICE verification by the maintainer

These compile and are logically wired, but were **not** run on the Apple TV
(shared device lock — compile‑only by instruction). Please verify on device:

1. **Music — album covers:** an album with no server art shows a Cover Art
   Archive / Deezer cover on album cards, the album detail header, and Now
   Playing / mini‑player.
2. **Music — Deezer artist art in Now Playing:** the full‑screen Now Playing
   background and the artist detail hero fall back to the Deezer artist
   `picture_xl` when the server has no artist image.
3. **Server‑art precedence:** items that *do* have server art still show the
   server art (the MetadataKit fallback must not override it).
4. **Plex GUID anime detection:** a Plex anime item (with `anidb://` /
   `anilist://` / `myanimelist://` GUIDs) is now classified as anime and gets
   AniList/Kitsu artwork — confirm Plex rails/detail resolve external ids
   (`includeGuids=1` working against a real Plex server).
5. **Plex cross‑provider matching:** Plex movies/TV with `imdb://` / `tmdb://`
   GUIDs resolve TMDb/TVmaze art the same way Jellyfin items do.
6. **No music regression:** playback, queue, Up Next and focus behaviour on the
   Music tab are unchanged.
