# FeatureSettings

The Settings screen and its detail pages. Profile-aware, integration-aware,
and the single place caption customization lives.

## Responsibility

- `SettingsView` — the root focused list (themes, profiles, servers &
  libraries, integrations, captions, about). `SettingsRowStyle` &
  `SettingsContext` provide the shared look + the environment needed by
  every detail page.
- `ProfileDetailView` — manage the active profile: rename, recolor,
  switch / sign out of accounts, configure the Plex Home-user mapping
  (`PlexLinkedUserDetailView`).
- `ServerDetailView` + `ServersAndLibrariesDetailView` — manage stored
  servers / accounts (`AccountStore`), pick which Jellyfin libraries the
  current profile includes, remove accounts.
- `IntegrationsDetailView` — Trakt OAuth sign-in & disconnect (delegates
  to `TraktService`).
- `PreferenceDetailViews` — captions / spoiler / diagnostics /
  Home-customization preferences. Caption customization renders the
  live preview via `CoreUI.CaptionSettingsCard` so what you see in
  Settings is what plays back.
- `SettingsAboutSection` — credits / attributions / version.

## Invariants

- **Profile-namespaced settings.** Per-user prefs (theme, captions,
  diagnostics, spoiler) are namespaced by the active profile id; the
  default profile uses no suffix so an upgrading install keeps existing
  values (`migrateLegacyIfNeeded` in `ProfileStore`).
- **No tokens here.** Account & Trakt token management is delegated to
  `FeatureAuth.AccountStore` / `TraktService.TraktTokenStore`.
- **Dual-provider.** Server/library management must work for both Plex
  and Jellyfin accounts (Plex Home-user mapping is Plex-specific, but
  the UI must clearly say so).
- **No persistence schema duplication.** Persistence lives in
  `CoreModels` / `FeatureAuth` / `TraktService`; this module only
  **edits** what they store.

## Where to look first

- `SettingsView.swift` — the row composition (the tree of detail pages).
- `ProfileDetailView.swift` — profile-scoped editing.
- `PreferenceDetailViews.swift` — caption / spoiler / diagnostics prefs.
