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

---

## Phase 2 — On-device artwork fixes (maintainer feedback)

After the first synthesis was tested on the Apple TV, the maintainer reported
two artwork problems. Both were root-caused in code and fixed additively. Build
verified `BUILD SUCCEEDED`, installed + launched on the Apple TV.

### Problem 1 — anime episodes showed no thumbnail

**FIX 1 — Guard Jellyfin image URLs on real image tags**
(`Sources/ProviderJellyfin/JellyfinProvider.swift`)
- Added a private `imageURL(for:kind:maxWidth:client:)` helper that returns `nil`
  when the DTO doesn't advertise the image (`ImageTags["Primary"/"Thumb"/"Logo"]`,
  or a non-empty `BackdropImageTags`). Previously item image URLs were built
  unconditionally, so an episode with no server Primary still got a URL that
  404'd into a blank card. Returning `nil` now lets the artwork fallback chain run.
- Applied to `posterURL`, `backdropURL`, `heroBackdropURL` in `map(item:)` and to
  the library `imageURL` mapping. `seriesPosterURL`/`fallbackArtworkURL` (series
  -level, keyed by `SeriesId`) and the existing `logoURL` helper are left as-is.
- Note: `ImageTags`/`BackdropImageTags` are returned by Jellyfin by default (the
  existing People/logo guards already read them), and are **not** valid
  `ItemFields` enum values — adding them to `Fields` risks a 400 on strict
  servers — so the `Fields` query params were intentionally left untouched.

**FIX 2 — Episode cards never render blank**
(`Sources/CoreUI/PosterCardView.swift`)
- The episode async fallback chain is now: real per-episode still
  (`ArtworkRouter .thumbnail`) → **series-level wide hero** → server series
  backdrop (`item.fallbackArtworkURL`).
- Added `seriesArtworkItem(for:)` which synthesizes a lightweight `.series`
  `MediaItem` from the episode (series id/title + normalized provider IDs +
  genres/tags) and calls `ArtworkRouter.shared.artworkURL(.hero, for:)`. For
  anime this yields the keyless AniList banner, so every anime episode card now
  shows the show banner instead of nothing. Same banner on every episode is
  acceptable; a blank card is not.

### Problem 2 — anime hero/background images were blurry

**FIX 3 — Sharper anime hero** (`Sources/MetadataKit/ArtworkRouter.swift`)
- Anime `.hero` chain changed `[anilist, tmdb, kitsu]` → `[tmdb, anilist, kitsu]`
  so the high-res TMDb `/original` backdrop is preferred when configured, with
  the keyless AniList banner (~1900×400) as fallback. Anime `.poster` left as
  `[anilist, kitsu, tmdb]`.

**FIX 4 — Stop stretching posters into the hero**
(`Sources/FeatureHome/DetailHeroView.swift`)
- Removed `backdrop.posterURL` (a vertical poster) from the hero backdrop
  `FallbackAsyncImage` `urls` list, keeping `heroBackdropURL` + `backdropURL`
  and the async `tmdbBackdropFallback`. A vertical poster is no longer stretched
  across the cinematic hero; an empty gradient hero is preferred over a distorted
  poster. Poster-style cards are untouched.

**No-BYOK preserved:** TMDb remains the optional tier. With no TMDb token every
fix degrades gracefully to keyless sources (AniList banner / server art).

### Phase 2 — needs on-device verification
1. **Anime episode cards:** episodes with no server still now show the show's
   AniList banner (keyless) — confirm no blank cards in anime episode rails.
2. **Anime episode stills (TMDb path):** with the maintainer's TMDb token, real
   per-episode stills still appear where TMDb numbering matches.
3. **Anime heroes sharp:** detail hero/background for anime is now the sharp TMDb
   `/original` backdrop (token configured), falling back to AniList banner.
4. **No stretched posters:** anime/movie detail heroes with no wide backdrop show
   a clean gradient rather than a stretched vertical poster.
5. **Western TV unaffected:** episodes/series with real server art still render
   that art (tag-guarding only nils out genuinely-absent images).

---

## Phase 3 — Merge of Plex self-heal branch (`thatcube-literate-train`)

Merged `origin/thatcube-literate-train` (HEAD `b4c49b1`) into this branch with
`--no-ff` to bring in a sibling session's Plex connection self-heal (a Docker
Plex server advertising an unroutable `172.18.0.1` "local" address yielded an
empty Home). Their files overlapped our Plex GUID-ingestion graft. Both sides
were preserved.

**Conflict (1 file):**
- `Sources/ProviderPlex/PlexClient.swift` — `metadata(ratingKey:)`. Their refactor
  routes detail fetches through the new `decode()` wrapper (send() + retry-once on
  `serverUnreachable` via `reportFailure`); our graft added `includeGuids=1` and
  used `http.decode(..., baseURL:)` directly. **Resolved** by keeping their
  `decode()` wrapper (self-heal) AND re-adding our `includeGuids=1` query, so the
  detail path is both self-healing and GUID-enriched.

**Auto-merged, verified both sides intact:**
- `CoreModels/MediaServer.swift` — `connectionURLs: [URL]?` (their back-compat field).
- `ProviderPlex/PlexConnectionResolver.swift` — new file (theirs), kept as-is.
- `PlexConnectionSelector.swift` — `ranked(from:)`, `connectionURLs`, both inits.
- `PlexAuthClient.swift` — `resolveServer()` + `connectionURLs(forServerID:authToken:)`.
- `PlexProvider.swift` — their `init(connectionRefresh:probe:)` + resolver wiring
  AND our `providerIDs(from:)` GUID parsing (`Self.providerIDs(from: dto)` in map).
- `FeatureAuth/PlexAuthService.swift` — persists `connectionURLs`.
- `AppShell/AppState.swift` — `.plex` factory wires `connectionRefresh`.
- `PlexClient.swift` — both inits (`baseURL:` compat + `resolver:`), `baseURL` ==
  `resolver.current`; our `includeGuids=1` present in `containerQuery` (list) and
  the detail path.
- `PlexDTOs.swift` — our `Guid`/`PlexGuid` DTO intact.

**Verification:** `ProviderPlexTests` 61/61 passed (tvOS Simulator); full device
build `BUILD SUCCEEDED`. No Apple TV install/launch (forbidden for the merge).
