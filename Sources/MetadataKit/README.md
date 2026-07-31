# MetadataKit

Artwork & metadata enrichment for media items, on top of the art that the
user's own server already supplies. TMDb leads where it's the best source and
a **fallback chain** stands behind every field, so no single provider —
keyed or keyless — is load-bearing.

See `docs/METADATA_ARCHITECTURE.md` for the full design and the
provider/fallback rationale.

## Responsibility

- `ArtworkRouter` — the single front door for resolving external art.
  Classifies a `MediaItem` (anime / movie / tvShow / music), runs an
  ordered, content-type-specific fallback chain of providers, and memoizes
  the resolved URL in `MetadataDiskCache`.
- `ContentClassification` — turns a `MediaItem` into a routable
  `ContentType` using provider-supplied genre / external-id hints.
- Provider conformers — each isolated behind a small `ArtworkProviding`
  surface and individually unit-testable:
  - **AniList** (GraphQL) — anime hero / poster / score.
  - **Kitsu** (JSON:API) — anime fallback.
  - **TVmaze** — western-TV per-episode stills + posters.
  - **TheTVDB** (`TVDBArtworkProvider` / `TVDBClient`) — bundled keyed tier
    for movie/TV posters + wide backdrops + ids/overview (and TMDb's main
    fallback). Attribution required — see the app's
    Settings → Attributions & Licenses and the repo README.
  - **Wikidata / Wikipedia** — cross-domain image lookups, used as last-mile
    backstop and to resolve canonical ids.
  - **Music artwork** (`MusicArtworkProviders`) — Deezer artist
    `picture_xl` + Cover Art Archive / MusicBrainz album covers.
  - **TMDb** (`TMDbMetadataProvider`) — bundled keyed source for backdrops
    / posters / per-episode stills / logos; first choice for movies and
    western TV, but always behind a fallback chain. Attribution required.
- `MetadataDiskCache` — small persistent KV cache for resolved URLs so a
  library is enriched with a one-time burst of calls, then effectively
  none.
- `MetadataHTTP` — internal lightweight `URLSession`-based fetcher with
  per-host rate limiting (so per-IP APIs stay within their budget).

## Invariants

- **No user keys required.** The shipped keys (TMDb, TheTVDB) are bundled;
  a user *may* supply their own TMDb token in Settings, but never has to.
- **No single provider is load-bearing.** Every field resolves through a
  fallback chain, so a revoked, throttled or retired key degrades quality,
  never function. See `MetadataProviderConfig`.
- **No UI imports.** Pure logic. Compiles on Linux.
- **Best-effort, non-throwing at the seam.** A failed provider returns
  `nil` URLs — features never block on metadata.
- **Cached aggressively.** Resolved URLs persist across launches in
  `MetadataDiskCache`; decoded bytes are cached by `CoreUI`'s
  `ArtworkImageCache`.

## Where to look first

- `ArtworkRouter.swift` — content classification + fallback chains.
- `MetadataProviderConfig.swift` — how the TMDb tier is wired.
- `ContentClassification.swift` — the anime / movie / tvShow / music
  decision.
- `docs/METADATA_ARCHITECTURE.md` — the full architectural story.
