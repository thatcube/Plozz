# Plozz Metadata & Artwork Architecture

> Resilient, no‑setup metadata/artwork enrichment for a tvOS home‑media client.
> Designed for **anime‑first** excellence, gorgeous heroes/episode
> thumbnails/posters/logos for **movies, TV, anime and music**, and **useful**
> ratings — with **no "bring your own API key" (BYOK)** required of the user.

---

## 1. The policy, stated plainly

Plozz enriches a user's own Jellyfin/Plex library with external artwork, metadata
and ratings. Which source answers a given field is decided by four rules, in this
order:

0. **The user's own server comes first, for anything it actually has.** External
   providers *fill gaps and upgrade junk* — they do not replace what the server
   already supplies. See "Rule 0" below, since this is the rule most easily got
   wrong.
1. **Otherwise, whatever gives the user the best result.** Coverage, artwork
   quality, correct matches, speed. Nothing else outranks this.
2. **It must be free to use.** Plozz will not take on a provider that costs money
   — not for the maintainer, not for the user. A source that is only good behind a
   paid tier is not a candidate.
3. **Nothing may be load‑bearing.** Every field has a fallback chain, so any single
   provider can vanish without breaking the app.

### Rule 0 — the user's server is a first‑class source, not a last resort

It is tempting to read the server as the sad fallback you land on when every real
provider failed. That is backwards. The server usually *wins* rule 1 outright:

- **It's instant.** The data is already on the LAN, or already in the payload that
  drew the screen. No search call, no id resolution, no round trip. A marginally
  nicer poster that pops in 800 ms later is a *worse* experience, not a better one.
- **It's free at any scale and works offline** — the only source of which both are
  unconditionally true (rule 2, and the reason rule 3 is satisfiable at all).
- **It's often more *correct in intent*.** The user may have deliberately set custom
  art or fixed a title, and their other clients show it. Silently overriding curated
  data with a fuzzy title match is a bug, not an upgrade.

The server is also frequently **wrong or empty** — missing episode stills, no clear
logos, no wide backdrops, a bad scrape. That is precisely the gap external providers
exist to fill, and why they must never be *removed* on rule‑0 grounds. So:

> **Server first for whatever it actually has; external providers fill gaps and
> upgrade junk; user‑curated data is never silently overridden.**

Two boundaries make that safe in practice:

- **Identity is server‑authoritative.** An id the server already stamped outranks
  any id an external provider inferred from a title match. Enrichment may *add*
  ids, never overrule them.
- **Artwork is the only field a user may flip.** `preferOnlineArtwork` (default
  **off**) lets someone who knows their server art is poor put configured external
  providers ahead of it — for artwork only. It never reorders text or identity.

In code this is `MetadataEnrichmentConfig.precedenceSources(for:query:)`, which
returns `[.localNFO, .server, .localArtwork, .embedded] + online` by default and
only moves `online` ahead when `preferOnlineArtwork` is set on an artwork field.

### Rules 1–3 — choosing among the external providers

**No provider is preferred as a matter of policy — TMDb included.** There is no
"TMDb‑first" rule and no "keyless‑first" rule. Each chain is just an ordering of
whichever free sources currently produce the best result for that content type and
field, and any of them can be reordered or dropped the moment something better or
cheaper exists.

**Keys are neither preferred nor avoided.** A key is not a badge of quality and not
a disqualifier — it's an implementation detail of reaching a source. Where a field
needs no key to be answered well, no key is used. Where the best free answer happens
to sit behind a key, Plozz ships that key rather than degrading the experience, and
**picks the best key for that job**. TMDb and TheTVDB tokens are baked into release
builds at build time (from a gitignored secrets file — never committed to the repo)
purely on that basis.

**What Plozz does not do is *rely* on any of them.** A key can be revoked,
throttled, repriced or retired, and a provider can change its terms — at which
point rule 2 alone would remove it. So the rule is:

> **Use whatever serves the user best for free; never be load‑bearing on it.**

Every field resolves through an ordered **fallback chain**. If TMDb is disabled,
rate‑limited or failing, the same field is answered by TheTVDB, TVmaze, AniList,
Kitsu, Wikidata/Wikipedia — and under all of them, the user's own server. Losing a
provider costs *quality*, never *function*, and never requires a code change.

> ⚠️ **Retired claim.** Earlier revisions of this document said TMDb's terms
> forbid shipping a key and that public builds therefore have TMDb disabled. That
> was wrong. There is no "keyless build" policy: builds ship the key when it earns
> its place, and the keyless providers are chain members on their own merits — not
> a moral alternative to keys.

Anime is the clearest illustration that this is not a keyed‑vs‑keyless question at
all: TMDb/OMDb are western‑media first, so for the anime‑heavy libraries Plozz
targets, AniList/Kitsu ids and art are simply *better* — and they lead those chains
for that reason, not because they're free of a key.

## 2. Why the chains are ordered the way they are

Rules 1 and 2 decide *who's in* a chain (rule 0 having already given the server
first refusal). Ordering within it also weighs how each source behaves **at
scale**, since a provider that collapses under load stops serving users well
(rule 1) and can start costing money (rule 2).

> **Per‑IP APIs scale infinitely; shared‑key APIs have a blast radius.**

When a device calls an API **directly from its own IP**, there is no shared quota to
exhaust and no key to ban: 100k users = 100k independent rate‑limit buckets. A
shared credential is different — one traffic spike can take a source down for
*everyone* at once.

So:

- TMDb rate‑limits **by requesting IP** rather than by key, so every household gets
  its own budget however many people run the app — which is why shipping its key is
  cheap and safe, and why it can sit early in a chain when its art is the best.
- Providers whose credential carries a shared blast radius (e.g. Trakt, which has
  firewall‑blocked a distributed app's client id over runaway traffic) sit **later**
  in a chain, answering only what the earlier source couldn't — keeping aggregate
  traffic on them low.
- Providers with hard *global* free ceilings (OMDb's 1,000 requests/day **total**)
  can never be load‑bearing at all, however good their data is.
- Keyless per‑IP sources make excellent unlimited backstops — and for anime they're
  frequently the best answer outright.

## 3. The provider set

### Sources reached with a bundled key

| Provider | Content | Capabilities | Limits |
|---|---|---|---|
| **TMDb** | Movies, western TV, anime | backdrops/heroes, posters, **clear logos**, **per‑episode stills**, cast | free; per‑IP, generous |
| **TheTVDB** | Movies, TV | posters, wide backdrops, ids/overview, cast, air schedule | free under $50k/yr parent‑company revenue (FOSS discount); per‑key |

The image *bytes* for TMDb always come straight from its keyless CDN
(`image.tmdb.org`), so only the small JSON calls consume any budget.

### Sources that need no key

Every device talks to these directly. No key, no account, no proxy.

| Provider | Content | Capabilities | Keyless? | Limit (per IP) |
|---|---|---|---|---|
| **AniList** (GraphQL) | Anime | hero (`bannerImage`), poster (`coverImage`), **rating** (`averageScore`), airing schedule | ✅ public reads | ~90 req/min |
| **Kitsu** (JSON:API) | Anime | poster/hero fallback | ✅ | ~30 req/min |
| **TVmaze** | Western TV | **per‑episode stills**, poster, episode summaries | ✅ | 20 req/10s |
| **Wikidata / Wikipedia** | Any | logos, images, plot overviews, canonical ids | ✅ | generous |
| **Deezer** | Music | artist `picture_xl` (hero), album `cover_xl` | ✅ public | generous |
| **MusicBrainz + Cover Art Archive** | Music | album front cover (fallback) | ✅ (UA required) | ~1 req/s |

### Optional extras (never required, never charged for)

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

Read the orderings as *current judgements about quality*, not as a ranking of
providers: TMDb heads several video chains today because its art is the best free
art available for those fields, and AniList/Kitsu/TVmaze head others for exactly the
same reason. Reordering a chain when a source gets better or worse is expected and
requires no architectural change.

Note that no row is a single cell: every field a keyed source heads has at least one
independent source behind it. That is rule 3 expressed as data — adding a
single‑source chain for a *new* field is the thing to avoid.

This table covers only the **external** half of the chain. Per rule 0 the user's
own server art is tried first and these providers fill gaps and upgrade junk —
unless the user has turned on `preferOnlineArtwork`, which moves them ahead for
artwork only. With the TMDb tier off, anime, TV and music still get great art;
western‑movie heroes/logos degrade to TheTVDB, Wikidata/Wikipedia and server art.

## 5. Why the user never needs a key

1. **Where a key is needed, the app brings its own.** TMDb and TheTVDB are bundled;
   no account, no key paste, no setup screen to get through.
2. **Anime, episode thumbnails and music also work with no key at all** via the
   per‑IP tier — the parts the primary user cares about most keep working even in
   a build with every key stripped out.
3. **User‑supplied credentials are strictly additive.** A user's own TMDb token
   (and the optional OMDb key) can personalize or raise the ceiling of enrichment;
   neither is required for a good default experience, and neither costs the user
   anything to skip.

So BYOK is not merely discouraged — it is **structurally unnecessary**, both when
the shipped keys are present and if they ever go away.

## 6. Scaling story for 100k+ users

- **The keyless sources are embarrassingly parallel.** 100k devices = 100k separate
  per‑IP rate buckets against AniList/Kitsu/TVmaze/Wikidata/Deezer/MusicBrainz. No
  shared quota, no key to ban. Each device also makes few calls: results are cached
  on disk (below), so steady‑state traffic per device is near zero.
- **TMDb is per‑IP too**, so its bundled key scales with the user base rather than
  against it — one of the reasons it's affordable to ship. If that ever changes, the
  optional proxy collapses 100k users into a few thousand unique upstream calls, and
  the chains keep working regardless.
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
- **Rule 0 is also the cheapest path.** Because the server answers first for
  everything it has, the external providers are only ever asked about genuine gaps
  — so a well‑scraped library generates almost no third‑party traffic at all.

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
- **"Free" is a live constraint, not a one‑time check.** Any provider that starts
  charging, or gates its useful data behind a paid tier, has to be demoted or
  dropped — which is workable precisely because nothing is load‑bearing.
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
