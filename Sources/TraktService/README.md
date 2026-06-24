# TraktService

Optional Trakt.tv integration: OAuth sign-in, scrobble (start / pause /
stop) while playing, and watched-state sync helpers. Disabled until the
user signs in.

## Responsibility

- `TraktConfig` — client id / secret / base URLs / scopes for the user's
  Trakt app registration.
- `TraktClient` — low-level wrapper around the shared
  `CoreNetworking.HTTPClient` that centralises Trakt's required headers
  (`trakt-api-version`, `trakt-api-key`, bearer `Authorization`).
- `TraktAuthService` — device-code OAuth flow (show a code, poll for
  completion) + refresh-token rotation. Tokens never leave this module.
- `TraktTokenStore` — Keychain-backed persistence for access/refresh
  tokens. Per-profile namespaced from `AppShell` so each household profile
  has its own Trakt identity.
- `TraktScrobbler` — translates `FeaturePlayback` progress events into
  Trakt scrobble start/pause/stop calls, with thresholds, debouncing, and
  graceful no-op when disabled.
- `TraktModels` — Trakt API DTOs / response shapes, mapped onto domain
  types at the seam.

## Invariants

- **No UI imports.** Linux-portable.
- **Tokens stay in Keychain.** Never logged, never written to plists.
  `HTTPClient` redacts the bearer `Authorization` header.
- **Failures degrade silently.** A network failure or an expired token
  pauses scrobbling without crashing playback or breaking the UI.
- **Pluggable / optional.** When the user isn't signed in to Trakt, the
  service short-circuits to no-ops — features must remain functional
  without it.

## Where to look first

- `TraktService.swift` — the public façade `AppShell` consumes.
- `TraktAuthService.swift` — sign-in / refresh flow.
- `TraktScrobbler.swift` — playback → Trakt event mapping.
