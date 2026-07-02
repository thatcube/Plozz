# Plozz Metadata & Artwork Architecture

> Scalable, keyless‑to‑the‑user metadata/artwork enrichment for a tvOS home‑media
> client. Designed for **anime‑first** excellence, gorgeous heroes/episode
> thumbnails/posters/logos for **movies, TV, anime and music**, and **useful**
> ratings — powered by **free APIs that scale to hundreds of thousands of users**
> with **no "bring your own API key" (BYOK)**.

---

## 1. The problem, restated

Plozz enriches a user's own Jellyfin/Plex library with external artwork and
ratings. The legacy path used **TMDb** (posters, backdrops, per‑episode stills,
logos, trailers) and **OMDb** (IMDb/RT/Metacritic ratings) via keys substituted
in at build time. Two structural problems:

1. **It doesn't scale and isn't compliant.** TMDb's developer terms **forbid
   embedding the API key in an open‑source / distributed client**. Plozz is open
   source with a public repo, so the public build necessarily ships **empty**
   TMDb/OMDb keys — meaning keyless builds get **no external art or ratings at
   all**. A single shared key would also be rate‑limited/banned at scale, and
   OMDb's free tier is **1,000 requests/day total** — useless for 100k users.
2. **Anime coverage is weak.** TMDb/OMDb are western‑media first. The maintainer's
   primary user watches mostly anime, where AniList/AniDB/MAL ids and art matter.

## 2. The core insight

> **Keyless per‑IP APIs scale infinitely; shared‑key APIs don't.**

When each user's device calls an API **directly from its own IP** with **no key**,
there is no shared quota to exhaust and no key to ban. 100k users = 100k
independent rate‑limit buckets. This is the opposite of a shared embedded key,
where 100k users hammer one bucket. So the architecture makes **keyless per‑IP
providers the backbone**, and treats the one provider that *requires* a key (TMDb)
as an **optional, maintainer‑hosted, edge‑cached tier** — never a user key.

## 3. Two tiers

### Tier 1 — Keyless per‑IP backbone (default, zero infrastructure)

Every device talks to these directly. No key, no account, no proxy. This tier
alone makes the **anime + episode‑thumbnail + music** experience great.

| Provider | Content | Capabilities | Keyless? | Limit (per IP) |
|---|---|---|---|---|
| **AniList** (GraphQL) | Anime | hero (`bannerImage`), poster (`coverImage`), **rating** (`averageScore`) | ✅ public reads | ~90 req/min |
| **Kitsu** (JSON:API) | Anime | poster/hero fallback | ✅ | ~30 req/min |
| **TVmaze** | Western TV | **per‑episode stills** (real thumbnails), poster | ✅ | 20 req/10s |
| **Deezer** | Music | artist `picture_xl` (hero), album `cover_xl` | ✅ public | generous |
| **MusicBrainz + Cover Art Archive** | Music | album front cover (fallback) | ✅ (UA required) | ~1 req/s |

### Tier 2 — Optional TMDb proxy (maintainer infrastructure, NOT user BYOK)

TMDb is still the gold standard for **western movie/TV backdrops, clear logos and
episode stills**. Because its terms forbid a distributed key, Plozz reaches it
through a **self‑hostable caching proxy** that holds **one** key **server‑side**
(fully terms‑compliant) and caches responses at the edge:

```
                                       ┌─────────────────────────────┐
 100k devices ── JSON metadata req ──▶ │  TMDb caching proxy         │ ──▶ TMDb API
   (no key)                            │  (1 server-side key, CDN)   │     (1 key)
       │                               └─────────────────────────────┘
       │   image bytes (keyless CDN)
       └────────────────────────────────────────────▶ image.tmdb.org  (no key, uncapped)
```

Key properties:

- **Only the small JSON metadata calls** (search + `/images`) traverse the proxy.
  The **image bytes always come straight from TMDb's keyless CDN** (`image.tmdb.org`),
  so the proxy stays tiny and the heavy byte path is uncapped.
- **Cache hit rate approaches 100%.** Metadata for "Breaking Bad S02E05 stills" is
  identical for every user, so after the first request it's served from cache.
  100k users browsing a few thousand popular titles collapse to a few thousand
  unique upstream TMDb calls — comfortably inside TMDb's limits with one key.
- **The app ships with the proxy URL empty by default.** If the maintainer runs a
  public instance, the build can point at it; if it's unset or unreachable, the
  TMDb tier silently turns off and Tier 1 + the user's own server art carry the
  app. The **user never sees a key or an account.**
- A reference proxy is a ~30‑line Cloudflare Worker / Deno Deploy / Fly.io app:
  inject `Authorization: Bearer <key>`, forward to `api.themoviedb.org`, set
  `Cache-Control: public, max-age=...`. Self‑hosting is documented for anyone who
  forks Plozz.

> There is also a `directToken` mode that reads a local `TMDB_BEARER_TOKEN` — this
> exists **only** for the maintainer's own local/TestFlight builds and is never
> committed or distributed. The default public path is **proxy or off**.

## 4. Provider routing matrix (content type × capability)

`ArtworkRouter` classifies each item then runs an ordered **fallback chain** per
(content type, artwork kind). First non‑nil URL wins; results are disk‑cached.

| Content | Hero | Poster | Thumbnail (episode) | Logo | Rating |
|---|---|---|---|---|---|
| **Anime** | AniList → Kitsu → TMDb proxy | AniList → Kitsu → TMDb proxy | TMDb proxy → TVmaze | TMDb proxy | **AniList** → OMDb |
| **Movie** | TMDb proxy | TMDb proxy | — | TMDb proxy | OMDb (IMDb/RT/MC) |
| **TV** | TMDb proxy → TVmaze | TMDb proxy → TVmaze | TMDb proxy → **TVmaze** | TMDb proxy | OMDb |
| **Music** | Deezer (artist) | Deezer/MB+CAA (album) | — | — | — |

The user's **own server art is always tried first** by the existing view layer;
these providers fill gaps and upgrade junk/missing art. When the TMDb proxy is
off, anime/TV/music still get great art from the keyless tier; only western‑movie
heroes/logos degrade to server art.

## 5. How BYOK is avoided (explicitly)

1. **Anime, episode thumbnails (TV), and music are 100% keyless** via Tier 1 —
   the parts the primary user cares about most need no infrastructure at all.
2. The **only** credential anywhere is **maintainer infrastructure** (one
   server‑side TMDb key behind an optional proxy). It is invisible to users: no
   account, no key paste, no setup.
3. OMDb and a direct TMDb token remain **optional local enhancements** for the
   maintainer's own builds, isolated behind config and absent from the public
   build. The **default experience is fully keyless and good.**

This satisfies the hard constraint: BYOK is not just discouraged, it's
**structurally unnecessary** for a great default experience.

## 6. Scaling story for 100k+ users

- **Tier 1 is embarrassingly parallel.** 100k devices = 100k separate per‑IP rate
  buckets against AniList/Kitsu/TVmaze/Deezer/MusicBrainz. There is no shared
  quota and no key to ban. Each device also makes few calls: results are cached on
  disk (below), so steady‑state traffic per device is near zero.
- **Tier 2 collapses via caching.** Popular catalogs are small and shared; an edge
  cache turns 100k users into a few thousand unique upstream TMDb metadata calls.
  Image bytes never touch the proxy (keyless CDN). One key suffices.
- **Three‑layer cache** minimizes every kind of request:
  1. **In‑memory** `ArtworkImageCache` (decoded UIImages) — already in the app.
  2. **Persistent disk** `MetadataDiskCache` — caches *resolved URLs* per
     `(contentType, kind, stableID)` with **positive TTL 30 days** and **negative
     TTL 3 days** (so a miss isn't re‑queried every launch). Keyed by external id
     where possible, so two items for the same show share one lookup.
  3. **HTTP `URLCache`** for the underlying responses/bytes.
- **Graceful degradation.** Every provider call is best‑effort and returns `nil`
  on any failure (never throws). A dead provider just falls through the chain; a
  dead proxy disables Tier 2 without touching Tier 1.

## 7. Code architecture

New Foundation‑only module **`MetadataKit`** (depends on `CoreModels` +
`CoreNetworking`), so it has no UI coupling and is unit‑testable:

```
Sources/MetadataKit/
  ContentClassification.swift   ContentType + ContentClassifier + AnimeIDs
  MetadataModels.swift          ArtworkKind, MetadataQuery (Sendable), ArtworkProvider
  MetadataHTTP.swift            best-effort JSON GET/POST (+UA, +headers); never throws
  MetadataDiskCache.swift       actor; persistent resolved-URL cache (TTL + negative)
  MetadataProviderConfig.swift  TMDbAccess (proxy | directToken | disabled), .resolved(bundle:)
  AniListArtworkProvider.swift  keyless anime hero/poster by id/idMal/search
  KitsuArtworkProvider.swift    keyless anime fallback
  TVmazeArtworkProvider.swift   keyless western-TV episode stills + poster
  MusicArtworkProviders.swift   Deezer + MusicBrainz/CAA
  TMDbMetadataProvider.swift    proxy/token-gated TMDb (hero/poster/logo/still)
  ArtworkRouter.swift           actor; classify → fallback chain → disk cache
```

- **`ArtworkRouter.shared`** is the single front door. `artworkURL(_:for:)` takes a
  `MediaItem` (or `MetadataQuery`) + `ArtworkKind`; music has
  `artistImageURL`/`albumCoverURL`.
- **Ratings**: `AniListRatingsProvider` (keyless, returns an `.anilist` percent
  rating) is composed with OMDb (when a key is present) via
  `CompositeRatingsProvider`, all wrapped in the existing `CachingRatingsProvider`
  in `RatingsServiceFactory`. New `RatingSource.anilist` in `CoreModels`.
- **View wiring**: `PosterCardView`, `DetailHeroView`, and `SeriesDetailView`
  fallbacks now route through `ArtworkRouter` instead of calling TMDb directly.
  The legacy `TMDbArtworkResolver` is retained only for trailers and company
  logos.
- **Concurrency**: strict‑concurrency clean. Providers are `Sendable` structs;
  router and caches are `actor`s; queries are value types.

## 8. Trade‑offs & honest limitations

- **Per‑IP limits are per device, not per app.** A user behind CGNAT sharing an IP
  with many Plozz users *could* in theory hit a provider's per‑IP limit, but the
  disk cache makes steady‑state traffic tiny, so this is unlikely in practice.
- **AniList rating is a single 0–100 "average score".** It's the *useful* number
  for anime, but it isn't IMDb/RT. For anime we surface AniList; for western
  movies/TV, OMDb (if configured) still gives IMDb/RT/Metacritic.
- **Western‑movie heroes/logos depend on Tier 2.** With no proxy configured,
  movies fall back to the user's own server art. Anime/TV/music do not depend on
  Tier 2.
- **Music view wiring is deferred.** Deezer/MusicBrainz providers and the router's
  music methods exist and are callable, but the music feature views are not yet
  switched over (see Phase 4). This bounds build/regression risk.
- **The default public build has no proxy URL**, so out of the box it behaves like
  today for western movies until the maintainer hosts/points at a proxy — but
  anime/TV/music/ratings are immediately better with zero setup.

## 9. Phased implementation plan

- **Phase 1 — Keyless backbone (DONE).** MetadataKit module, classifier, AniList +
  Kitsu + TVmaze providers, disk cache, router, AniList ratings, view wiring for
  hero/poster/thumbnail/logo fallbacks. Default build is fully keyless.
- **Phase 2 — Optional TMDb proxy tier (DONE, infra optional).** Proxy/token‑gated
  `TMDbMetadataProvider`, `MetadataProviderConfig`, `TMDBProxyBaseURL` Info.plist
  key + xcconfig default (empty). Ship the reference proxy + docs.
- **Phase 3 — Music providers (DONE in MetadataKit).** Deezer + MusicBrainz/CAA
  providers and router music methods.
- **Phase 4 — Music view wiring (FUTURE).** Route `FeatureMusic` artwork through
  the router's music methods.
- **Phase 5 — Enrichment polish (FUTURE).** Anime character art from AniList,
  trailer routing through the proxy, smarter title‑match scoring, prefetch tuning.

---

*Verification: `swift test` runs the pure-logic suite without linking
AetherEngine's tvOS-only FFmpeg xcframeworks; the tvOS simulator/app build
remains the authoritative compile/link check for the on-device engine.*
