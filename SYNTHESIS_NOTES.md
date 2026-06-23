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

---

## Phase 4 — Hero horizontal-overflow fix (long titles)

On-device the detail hero appeared shifted sideways: the title and the focusable
Play button were pushed off the left edge, and the backdrop looked "too wide".

**Root cause:** `DetailHeroView.titleText` was a plain `Text` with no width cap
or line limit. A long show title (e.g. "I've Been Killing Slimes for 300 Years
and Maxed Out My Level Season 2") rendered as a single line far wider than the
screen, which sized the hero/ScrollView content past the viewport and shoved the
whole page horizontally — hiding the left side (title + focus). Every other hero
text block was already capped at `maxWidth: 960`; the title and the subtitle/
metadata lines were not.

**Fix** (`Sources/FeatureHome/DetailHeroView.swift`):
- `titleText`: `.lineLimit(2)`, `.minimumScaleFactor(0.5)`,
  `.multilineTextAlignment(.leading)`, `.frame(maxWidth: 1200, alignment:
  .leading)` — long titles now wrap/scale within bounds instead of overflowing.
- Hero subtitle + metadata lines: added `.lineLimit(1)` +
  `.frame(maxWidth: 1200, alignment: .leading)` as overflow insurance.

No artwork/provider behaviour changed; this is layout-only. Build BUILD
SUCCEEDED; installed + launched on the Apple TV.

---

## Phase 5 — Hero overflow (hard containment) + anime episode thumbnails

Two issues persisted on-device after Phase 4:

### A. Hero page still shifted right (focus off-screen left)
The Phase-4 per-text caps were not enough: on tvOS, *any* focusable element (the
Play button) inside content wider than the scroll viewport makes the page pan
horizontally, and the hero content column had no hard width cap of its own — a
wide badge/ratings strip, an oversized logo, or any future row could still push
it past the screen. (A vertical `ScrollView` clips vertical overflow but the
focus engine will still pan horizontally to "frame" a focused element in
over-wide content.)

**Fix** (`Sources/FeatureHome/DetailHeroView.swift`):
- Added a hard `.frame(maxWidth: Self.screenWidth, alignment: .leading)` on the
  hero content `VStack` *after* its paddings, so the column can never report a
  width greater than the viewport regardless of which inner row is wide. Added a
  `screenWidth` helper (UIScreen width, 1920 fallback off-device).
- This is the definitive containment: even if an inner row overflows it now draws
  past the right edge (clipped) instead of widening the page and panning focus
  off-screen.

### B. Many anime episodes showed no thumbnail (and no placeholder)
The Phase-2 episode fallback synthesizes a *series* item from the episode and asks
`ArtworkRouter` for a `.hero` (TMDb backdrop, else the keyless AniList banner).
But Jellyfin/Plex **episodes rarely carry the show's anime ids or "Anime"
genre**, so the synthesized series item classified as `tvShow` → hero chain
`[tmdb]` only → no AniList → blank for anime when TMDb has no match.

**Fix** (propagate series anime context onto episodes, mirroring the existing
`SeriesTmdb` stamp):
- `Sources/MetadataKit/ContentClassification.swift`: new public
  `ContentClassifier.isAnimeProviderIDKey(_:)` so callers can copy just a series'
  anime ids (AniList/AniDB/MAL/Shoko/Kitsu).
- `Sources/FeatureHome/ItemDetailViewModel.swift`: capture the series' anime ids +
  `isAnime` at load (`captureSeriesContext`) and, in `stampSeriesTMDb`, stamp each
  episode with the series' anime ids and an "Anime" genre when the show is anime.
- `Sources/FeatureHome/SeriesDetailView.swift`: same stamp for the flat
  `looseEpisodes` path (now takes the full `series`).

Because `AniListArtworkProvider` falls back to a **title search** when no id is
present, the only requirement for the keyless banner is that the synthesized
series item classifies as anime — which this stamping guarantees. Result: an
anime episode with no still now shows the show's AniList banner (keyless, no TMDb
needed); the same banner on every episode of a show is acceptable vs. a blank
card.

Build BUILD SUCCEEDED; installed + launched on the Apple TV from the verified
`CODESIGNING_FOLDER_PATH` of the fresh build (to rule out a stale install).

**Still needs on-device verification by the maintainer:**
- Open an anime series detail page: the hero/Play button should be on-screen at
  the left immediately (no rightward page shift), for shows with long titles.
- Anime episodes with no server still should now show the show's banner instead
  of a blank card. Western-TV episodes are unaffected (still → TMDb/TVmaze).
- Confirm heroes still look sharp (TMDb `/original` when configured) and that
  removing TMDb would degrade gracefully to the keyless AniList banner.

## Phase 6 — Root-cause fix for the hero/page horizontal shift (4th pass)

Earlier passes (title caps, hero-column `screenWidth` cap) did NOT fix the
reported shift. Decisive on-device clue from the maintainer: the **hero image is
dead-centre in the viewport while the rest of the UI is pushed right** (focus
off the left edge), and there were "hundreds of tags." Root cause, verified in
code (and confirmed *not* caused by the graft — `git diff 6ff5a0a` shows the
graft only populated `providerIDs`, never `tags`; this is a base-level layout
bug the maintainer was comparing against competitor branches):

1. The hero backdrop uses `.ignoresSafeArea([.top, .horizontal])` to bleed
   edge-to-edge, which inflates the hero's **layout** width to the full panel
   (~1920) while the ScrollView's *safe* viewport is only ~1740 (tvOS overscan).
   The scroll-content `VStack` had **no width cap**, so it reported ~1920 and the
   page panned sideways.
2. `FlowLayout.sizeThatFits` returned the **summed width of every chip** when
   proposed an unbounded width — so a show with hundreds of server tags could
   balloon the column to many thousands of px, which SwiftUI then centres
   (hero appears centred, leading content thrown far off-screen left).
3. The prior `screenWidth` (=1920) hero cap was ≥ the safe viewport, so it could
   never actually constrain anything.

Fixes (all additive, keyless-safe, no provider/data changes):
- **DetailHeroView.swift**: hero content column cap `Self.screenWidth` →
  `.frame(maxWidth: .infinity)` (reports the *proposed* safe-viewport width and
  caps over-wide inner rows to it); removed the now-unused `screenWidth` helper.
- **SeriesDetailView.swift / ItemDetailView.swift**: cap the whole scroll-content
  `VStack` with `.frame(maxWidth: .infinity, alignment: .leading)`. The hero
  still bleeds full-width via its own `.ignoresSafeArea`, but its footprint — and
  any over-wide row below — can no longer inflate the column past the viewport.
- **DetailExtrasView.swift FlowLayout**: when proposed an unbounded width, wrap
  at a finite fallback (`UIScreen.main.bounds.width`) instead of summing all
  chips, so tags can never balloon the page.
- **DetailExtrasView.swift**: cap the displayed Tags strip to the first 40
  (anime can carry hundreds of AniDB keyword tags) — directly addresses the
  maintainer's "do they have a limit?" question.

### Needs on-device verification (maintainer)
- Anime **series** detail page: the page no longer shifts right; focus (Play
  button) is visible on the left on entry, with NO horizontal pan, even for
  shows with very long titles and/or hundreds of tags.
- The hero backdrop still bleeds edge-to-edge (full-width) and is centred.
- Tags strip now wraps to multiple lines and is capped at 40 chips.
- Movie detail pages (ItemDetailView) likewise no longer pan sideways.
