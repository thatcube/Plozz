# ProviderPlex

Plex implementation of `CoreModels.MediaProvider`. One of Plozz's two
first-class backends; co-equal with `ProviderJellyfin`.

## Responsibility

- `PlexProvider` — the `MediaProvider` conformer (libraries / hubs,
  continue-watching, latest, seasons/episodes, search, watched state,
  playback info / direct-play / transcode, progress reporting).
- `PlexClient` — low-level Plex API wrapper built on the shared
  `CoreNetworking.HTTPClient`. Centralises Plex's quirky required headers
  (`X-Plex-Token`, `X-Plex-Client-Identifier`, product/version, …).
- `PlexAuthClient` + `PlexPinFlow` — Plex **Link** "show a code, poll for
  completion" OAuth-PIN flow, plus the Home-user activation path that lets
  a Plozz profile map onto a Plex Home user (with optional PIN gate).
- `PlexConnectionResolver` + `PlexConnectionSelector` — pick the best
  reachable server connection from `plex.tv` (LAN vs WAN vs relayed),
  prioritising local & direct over relayed.
- `PlexDeviceProfile` — the direct-play / transcode capability matrix sent
  to the server, parameterised by whether the on-device decode engine
  (Plozzigen) is linked.
- `PlexDTOs` — Plex JSON shapes, mapped into `CoreModels` at the seam.
- `PlexProvider` also conforms to `SearchCatalogProviding`, using section-scoped
  type 1/2/4 pages for the fully local movie/series/episode index.

## Invariants

- **No UI imports.** Pure logic + DTOs.
- **Tokens never logged.** `X-Plex-Token` flows through `CoreNetworking`
  redaction; PIN values are never persisted (see `PlexPinFlow`).
- **All errors become `AppError`.**
- **Co-equal with `ProviderJellyfin`.** Any new `MediaProvider` capability
  must ship for Plex whenever it ships for Jellyfin (and vice versa).
- Home-user identity changes happen **in-memory only** — Plozz never
  rewrites the stored admin account's token; per-user tokens live in a
  short-lived override map.

## Where to look first

- `PlexProvider.swift` / `PlexClient.swift` — the `MediaProvider` entry.
- `PlexAuthClient.swift` + `PlexPinFlow.swift` — sign-in & Home-user PIN.
- `PlexConnectionResolver.swift` — how a usable base URL is chosen.
- `PlexDeviceProfile.swift` — what the server is told this device can play.
