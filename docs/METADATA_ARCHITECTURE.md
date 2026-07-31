# Plozz Metadata & Artwork Architecture

> Resilient, no-setup metadata/artwork enrichment for a tvOS home‑media client.
> Designed for **anime‑first** excellence, gorgeous heroes/episode
> thumbnails/posters/logos for **movies, TV, anime and music**, and **useful**
> ratings — with **no "bring your own API key" (BYOK)** required of the user.

---

## 1. The policy, stated plainly

Plozz enriches a user's own Jellyfin/Plex library with external artwork, metadata
and ratings.

**Plozz ships API keys.** A TMDb v4 read token and a TheTVDB v4 key are baked into
release builds at build time (from a gitignored secrets file — never committed to
the repo), and the app uses them wherever they are the best source. TMDb usually is,
for movie/western‑TV backdrops, posters, logos and per‑episode stills.

**What Plozz does not do is *rely* on any one of them.** A key can be revoked,
throttled, repriced or retired, and a provider can change its terms. So the rule is:

> **Prefer the best source; never be load‑bearing on it.**

Every field resolves through an ordered **fallback chain**. If TMDb is disabled,
rate‑limited or failing, the same field is answered by TheTVDB, TVmaze, AniList,
Kitsu, Wikidata/Wikipedia — or ultimately the user's own server art. Losing a
provider costs *quality*, never *function*, and never requires a code change.

> ⚠️ **Retired claim.** Earlier revisions of this document said TMDb's terms
> forbid shipping a key and that public builds therefore have TMDb disabled. That
> was wrong. There is no "keyless build" policy: builds ship the key, and the
> keyless providers exist as fallbacks and scale insurance, not as a substitute.

A secondary reason the fallback chains exist: **anime coverage.** TMDb/OMDb are
western‑media first, and AniList/AniDB/MAL ids and art matter a great deal for the
anime‑heavy libraries Plozz targets — so for some fields a keyless provider is
genuinely the *better* source, not just the backup.

## 2. Why the chains are built the way they are

> **Per‑IP APIs scale infinitely; shared‑key APIs have a blast radius.**

When a device calls an API **directly from its own IP** with **no key**, there is no
shared quota to exhaust and no key to ban: 100k users = 100k independent rate‑limit
buckets. Shared credentials are different — one bad actor or a traffic spike can
take a key down for *everyone* at once.

That doesn't mean avoiding keyed providers; it means placing them deliberately:

- TMDb rate‑limits **by requesting IP** rather than by key, so every household gets
  its own budget however many people run the app. That makes it safe to lead with.
- Providers whose credential carries a shared blast radius (e.g. Trakt, which has
  firewall‑blocked a distributed app's client id over runaway traffic) sit **later**
  in a chain, answering only what the earlier source couldn't — keeping aggregate
  traffic on them low.
- Keyless per‑IP providers make excellent unlimited backstops, and for anime they
  are frequently first choice on quality alone.

## 3. The provider tiers

### Bundled keyed sources (shipped, preferred where they win)

| Provider | Content | Capabilities | Limits |
|---|---|---|---|
| **TMDb** | Movies, western TV, anime | backdrops/heroes, posters, **clear logos**, **per‑episode stills**, cast | per‑IP, generous |
| **TheTVDB** | Movies, TV | posters, wide backdrops, ids/overview, cast, air schedule | per‑key, FOSS‑friendly licensing |

The image *bytes* for TMDb always come straight from its keyless CDN
(`image.tmdb.org`), so only the small JSON calls consume any budget.

### Keyless per‑IP sources (fallbacks — and first choice for anime)

Every device talks to these directly. No key, no account, no proxy.

| Provider | Content | Capabilities | Keyless? | Limit (per IP) |
|---|---|---|---|---|
| **AniList** (GraphQL) | Anime | hero (`bannerImage`), poster (`coverImage`), **rating** (`averageScore`), airing schedule | ✅ public reads | ~90 req/min |
| **Kitsu** (JSON:API) | Anime | poster/hero fallback | ✅ | ~30 req/min |
| **TVmaze** | Western TV | **per‑episode stills**, poster, episode summaries | ✅ | 20 req/10s |
| **Wikidata / Wikipedia** | Any | logos, images, plot overviews, canonical ids | ✅ | generous |
| **Deezer** | Music | artist `picture_xl` (hero), album `cover_xl` | ✅ public | generous |
| **MusicBrainz + Cover Art Archive** | Music | album front cover (fallback) | ✅ (UA required) | ~1 req/s |

### Optional extras (never required)

- **Self‑hosted TMDb caching proxy** (`TMDB_PROXY_BASE_URL`). When set it takes
  precedence over the bundled token: the small JSON calls traverse a proxy that
  holds the key server‑side and caches at the edge. Useful to absorb traffic at
  scale or to rotate the key without shipping a build. Image bytes still bypass it.

```
                                       ┌─────────────────────────────┐
 100k devices ── JSON metadata req ──▶ │  TMDb caching proxy         │ ──▶ TMDb API
   (no key)                            │  (1 server-side key, CDN)   │     (1 key)
       │                               └─────────────────────────────┘
       │   image bytes (keyless CDN)
       └──────────────────────────────────────────▶ image.tmdb.org  (no key, uncapped)
```

  A reference proxy is a ~30‑line Cloudflare Worker / Deno Deploy / Fly.io app:
  inject the `Authorization` bearer header server-side, forward to
  `api.themoviedb.org`, and set
  `Cache-Control: public, max-age=…`. Cache hit rate approaches 100% because
  "Breaking Bad S02E05 stills" is identical for every user.
- **The user's own TMDb token** (Settings ▸ "Your Own TMDB Key"). Purely optional:
  it runs lookups under the user's own credential/rate limit and its own cache and
  circuit‑breaker namespace. Never a prerequisite — the app is fully functional
  without it.
- **OMDb key** (IMDb/RT/Metacritic ratings). Optional local enhancement; its free
  tier (1,000 req/day *total*) makes it unsuitable as a shipped dependency, which is
  exactly why ratings never depend on it.

## 4. Provider routing matrix (content type × capability)

`ArtworkRouter` classifies each item then runs an ordered **fallback chain** per
(content type, artwork kind). First non‑nil URL wins; results are disk‑cached. The
live ordering is data in `CurrentMetadataPriority`:

| Content | Hero | Poster | Thumbnail (episode) | Logo | Overview | Rating |
|---|---|---|---|---|---|---|
| **Anime** | TMDb → AniList → Kitsu | AniList → Kitsu → TMDb | TMDb | TMDb → Wikidata → Wikipedia | Wikipedia | **AniList** → OMDb |
| **Movie** | TMDb → TheTVDB → Wikidata → Wikipedia | TMDb → TheTVDB → Wikidata → Wikipedia | TMDb | TMDb → Wikidata → Wikipedia | Wikipedia | OMDb (IMDb/RT/MC) |
| **TV** | TMDb → TheTVDB → Wikidata → Wikipedia | TMDb → TVmaze → TheTVDB → Wikidata → Wikipedia | TMDb → **TVmaze** | TMDb → Wikidata → Wikipedia | TVmaze | OMDb |
| **Music** | Deezer (artist) | Deezer/MB+CAA (album) | — | — | — | — |

Note that no row is a single cell: every field TMDb leads has at least one non‑TMDb
source behind it. That is the policy expressed as data — adding a TMDb‑only chain
for a *new* field is the thing to avoid.

The user's **own server art is always tried first** by the view layer; these
providers fill gaps and upgrade junk/missing art. With the TMDb tier off, anime, TV
and music still get great art; western‑movie heroes/logos degrade to TheTVDB,
Wikidata/Wikipedia and server art.

## 5. Why the user never needs a key

1. **The keys that matter ship with the app.** TMDb and TheTVDB are bundled; no
   account, no key paste, no setup screen to get through.
2. **Anime, episode thumbnails and music also work with no key at all** via the
   per‑IP tier — the parts the primary user cares about most keep working even in
   a build with every key stripped out.
3. **User‑supplied credentials are strictly additive.** A user's own TMDb token
   (and the maintainer's optional OMDb key) improve or personalize enrichment; they
   are never required for a good default experience.

So BYOK is not merely discouraged — it is **structurally unnecessary**, both when
the shipped keys are present and if they ever go away.

## 6. Scaling story for 100k+ users

- **The keyless tier is embarrassingly parallel.** 100k devices = 100k separate
  per‑IP rate buckets against AniList/Kitsu/TVmaze/Wikidata/Deezer/MusicBrainz. No
  shared quota, no key to ban. Each device also makes few calls: results are cached
  on disk (below), so steady‑state traffic per device is near zero.
- **TMDb is per‑IP too**, so the bundled key scales with the user base rather than
  against it. If that ever changes, the optional proxy collapses 100k users into a
  few thousand unique upstream calls, and the chains keep working regardless.
- **Three‑layer cache** minimizes every kind of request:
  1. **In‑memory** `ArtworkImageCache` (decoded UIImages).
  2. **Persistent disk** `MetadataDiskCache` — caches *resolved URLs* per
     `(contentType, kind, stableID)` with **positive TTL 30 days** and **negative
     TTL 3 days** (so a miss isn't re‑queried every launch). Keyed by external id
     where possible, so two items for the same show share one lookup.
  3. **HTTP `URLCache`** for the underlying responses/bytes.
- **Graceful degradation.** Every provider call is best‑effort and returns `nil`
  on any failure (never throws), and a circuit breaker sheds a provider that starts
  erroring. A dead provider just falls through the chain.

## 7. Code architecture

New Foundation‑only module **`MetadataKit`** (depends on `CoreModels` +
`CoreNetworking`), so it has no UI coupling and is unit‑testable:

```
Sources/MetadataKit/
  ContentClassification.swift   ContentType + ContentClassifier + AnimeIDs
  MetadataModels.swift          ArtworkKind, MetadataQuery (Sendable), ArtworkProvider
  MetadataHTTP.swift            best-effort JSON GET/POST (+UA, +headers); never throws
  MetadataDiskCache.swift       actor; persistent resolved-URL cache (TTL + negative)
  MetadataProviderConfig.swift  TMDbAccess (proxy | directToken | userToken | disabled)
  AniListArtworkProvider.swift  keyless anime hero/poster by id/idMal/search
  KitsuArtworkProvider.swift    keyless anime fallback
  TVmazeArtworkProvider.swift   keyless western-TV episode stills + poster
  MusicArtworkProviders.swift   Deezer + MusicBrainz/CAA
  TMDbMetadataProvider.swift    TMDb (hero/poster/logo/still/cast) via TMDbAccess
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
- **Quality, not function, depends on the shipped keys.** Without TMDb (contributor
  build, revoked key, outage) western‑movie heroes/logos and episode stills fall
  back to TheTVDB/TVmaze/Wikidata and the user's own server art — visibly worse in
  places, still working everywhere. Keeping that true is a review requirement for
  any new metadata feature.
- **Music view wiring is deferred.** Deezer/MusicBrainz providers and the router's
  music methods exist and are callable, but the music feature views are not yet
  fully switched over.

## 9. Phased implementation plan

- **Phase 1 — Fallback backbone (DONE).** MetadataKit module, classifier, AniList +
  Kitsu + TVmaze providers, disk cache, router, AniList ratings, view wiring for
  hero/poster/thumbnail/logo fallbacks. Works with every key stripped out.
- **Phase 2 — TMDb tier (DONE).** `TMDbMetadataProvider`, `MetadataProviderConfig`,
  bundled `TMDBBearerToken` plus the optional `TMDBProxyBaseURL` proxy and the
  user's own key, all behind the same fallback chains.
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
