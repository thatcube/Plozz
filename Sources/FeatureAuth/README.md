# FeatureAuth

Sign-in for Plex, Jellyfin, and Emby, an explicit session state machine that
keeps the UI free of ad-hoc boolean flags, and Keychain-backed account /
session persistence.

## Responsibility

- **Sign-in flows** — couch-friendly, no-password-typing-on-a-remote:
  - `QuickConnectService` + `QuickConnectViewModel` + `QuickConnectView` —
    Jellyfin **Quick Connect** (show a code on TV, approve elsewhere,
    poll until accepted; clean cancel / retry / expiry).
  - `PlexAuthService` + `PlexAuthViewModel` + `PlexLinkView` — Plex
    **Link** (`plex.tv/link`) PIN-code OAuth flow, polling for activation.
  - `PasswordSignInService` + `PasswordSignInViewModel` +
    `PasswordSignInView` — username/password sign-in for Emby and the
    fallback for Jellyfin servers without Quick Connect.
- **Session state machine** — `SessionStateMachine`. A pure `reduce`
  function over `(state, event) → state` (`launching → selectingServer →
  authenticating → authenticated → failed`). Unit-tested independently of
  any UI.
- **Persistence (split by sensitivity)** —
  - `SessionStore` (`SessionPersisting`) — Keychain for the access token,
    `UserDefaults` for non-secret metadata (server, user id/name, device
    id). Lets relaunch restore a session without re-login.
  - `AccountStore` — household-global, multi-account list (per-server
    logins). The single source of truth for "who can sign in" that
    `CoreModels.ProfileStore` subsets per profile.
  - `Keychain` — small wrapper around the Security framework used by
    both stores.
- **UI surfaces** — `AuthView` (root sign-in orchestrator) and the
  per-flow views above. `BrandQRCodeView` renders the Quick Connect /
  Plex Link codes as scannable QR + readable digits.

## Invariants

- **Tokens NEVER leave the Keychain.** Never written to `UserDefaults`,
  never logged. `AccountStore` is split-storage by design.
- **Pure state machine.** `SessionStateMachine` has no I/O — all side
  effects live in the services it produces events for.
- **Provider-appropriate sign-in.** Jellyfin uses Quick Connect or password,
  Emby uses password, and Plex uses Link.
- **Always cancellable.** Every flow must be Cancel-able from the remote
  without leaking polling tasks.

## Where to look first

- `SessionStateMachine.swift` — the pure auth-state reducer (start here
  to understand the auth lifecycle).
- `SessionStore.swift` + `AccountStore.swift` — what's persisted where.
- `QuickConnectService.swift` + `PlexAuthService.swift` — the two
  couch-friendly OAuth flows.
