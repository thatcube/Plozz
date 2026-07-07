# MetadataKit

Keyless-first artwork & metadata enrichment for media items, on top of the
art that the user's own server already supplies. The keyless backbone is
what lets Plozz ship a great anime + episode-thumbnail + music experience
**without bringing your own API key**.

See `docs/METADATA_ARCHITECTURE.md` for the full design and
the rationale for "keyless per-IP scales infinitely, shared-key doesn't".

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
    for movie/TV posters + wide backdrops + ids/overview (the one bundled
    source of movie posters). Attribution required — see the app's
    Settings → Attributions & Licenses and the repo README.
  - **Wikidata / Wikipedia** — cross-domain image lookups, used as last-mile
    backstop and to resolve canonical ids.
  - **Music artwork** (`MusicArtworkProviders`) — Deezer artist
    `picture_xl` + Cover Art Archive / MusicBrainz album covers.
  - **TMDb** (`TMDbMetadataProvider`) — optional Tier-2 source for backdrops
    / posters / per-episode stills / logos, used only when configured.
- `MetadataDiskCache` — small persistent KV cache for resolved URLs so a
  library is enriched with a one-time burst of calls, then effectively
  none.
- `MetadataHTTP` — internal lightweight `URLSession`-based fetcher with
  per-host rate limiting (so keyless APIs stay within their per-IP budget).

## Invariants

- **No user keys.** Default build is keyless. TMDb access only activates
  when an explicit bearer token is configured (see
  `MetadataProviderConfig`).
- **No UI imports.** Pure logic. Compiles on Linux.
- **Best-effort, non-throwing at the seam.** A failed provider returns
  `nil` URLs — features never block on metadata.
- **Cached aggressively.** Resolved URLs persist across launches in
  `MetadataDiskCache`; decoded bytes are cached by `CoreUI`'s
  `ArtworkImageCache`.

## Where to look first

- `ArtworkRouter.swift` — content classification + fallback chains.
- `MetadataProviderConfig.swift` — how the optional TMDb tier is wired.
- `ContentClassification.swift` — the anime / movie / tvShow / music
  decision.
- `docs/METADATA_ARCHITECTURE.md` — the full architectural story.
