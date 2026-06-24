# FeatureHome

Home rows, item detail, series/season experience, and the online-trailer
fallback when the user's server has no attached trailer.

## Responsibility

- **Home** — `HomeView` + `HomeViewModel` render the focused tvOS rows:
  Continue Watching, Latest, Recently Added (per library). `HomeLayout`
  centralises sizing/spacing so all rows feel uniform.
- **Multi-account aggregation** — `HomeAggregator` fans out across the
  active account set (`[ResolvedAccount]`) so Home is a merged view
  across multiple servers / profiles. Uses the `MediaProvider`
  abstraction; never imports a specific provider module.
- **Item detail** — `ItemDetailView` + `ItemDetailViewModel` and
  `DetailHeroView` / `DetailExtrasView` render the cinematic full-bleed
  backdrop, logo, overview, ratings, cast, and Play/Resume button. Works
  for movies, episodes, and people.
- **Series** — `SeriesDetailView` + `SeriesResume` provide one stable
  series backdrop with focus-driven season tabs and an episode rail; the
  hero text updates as focus moves without distracting backdrop swaps.
- **Library browsing** — `LibraryBrowseView` + `LibraryBrowseViewModel`
  for the per-library grid behind a Home row.
- **Trailers** — `OnlineTrailerSource` and `TrailerResolutionCache`
  handle the TMDb → YouTube fallback when the server has no attached
  trailer, by routing through `ProviderTrailers.YouTubeTrailerProvider`
  to surface a real `PlaybackRequest`.

## Invariants

- **Provider-agnostic.** All data flows through `MediaProvider`. No
  Jellyfin- or Plex-specific code paths above the provider seam.
- **Server art first.** External art (`MetadataKit`) is used as a
  fallback via `CoreUI.FallbackAsyncImage`, never as the default — the
  server's own backdrop/logo is always tried first.
- **`LoadState` everywhere.** Loading / empty / failure rendering uses
  `CoreUI.ContentStateView` so all surfaces feel identical.
- **No tokens in logs.** Provider calls log only opaque ids — never
  authorisation headers.

## Where to look first

- `HomeView.swift` + `HomeViewModel.swift` — the row composition.
- `HomeAggregator.swift` — multi-account fan-out.
- `ItemDetailViewModel.swift` + `SeriesDetailView.swift` — detail/series
  state coordination.
- `OnlineTrailerSource.swift` — the TMDb-keyless → YouTube fallback.
