# AppShell

The composition root. Wires every other module into a single running app
and owns the top-level navigation, profile selection, and provider
registry.

## Responsibility

- `AppState` — the `@Observable @MainActor` aggregate root. Holds the
  `ProfilesModel`, the active `[ResolvedAccount]`, the `ProviderRegistry`,
  Trakt service, Top Shelf publisher, and the active settings models for
  the current profile. Orchestrates:
  - profile switching (`switchProfile`, `saveProfile`, `removeProfile`,
    `rebuildSettingsModels`),
  - Plex Home-user activation (`pendingPlexPINRequest`, `submitPlexPIN`,
    `cancelPlexPIN` — the PIN is never stored),
  - per-profile Trakt namespace swap (`updateTraktForActiveProfile`).
- `RootView` + `MainTabView` — the root SwiftUI hierarchy
  (Auth → ProfileSelection → MainTab). Lives here because it must depend
  on every feature module.
- `ProfileSelectionView` — hosts `FeatureProfiles.ProfilePickerView` and
  the create/edit sheet for both the launch picker and Settings.
- `SystemProfileBridge` — narrow seam onto the tvOS `TVUserManager` API
  (`shouldStorePreferencesForCurrentUser`) for the `user-management`
  entitlement.
- `AddAccountView` — first-run "add another server" flow that routes
  into `FeatureDiscovery` and `FeatureAuth`.
- `LibraryDiscoveryModel` — per-account "what libraries does this server
  expose?" coordination.
- `MediaItemActionCoordinator` — the cross-feature action bus (play,
  resume, mark watched, open detail) so any view can request an action
  without knowing the playback / detail routing.
- `PlaybackEngineComposition` — the **only** module that imports
  `EngineMPV` (and any future engine packages). Builds the
  `EngineFactory` closure injected into `FeaturePlayback`, keeping libmpv
  out of every other module's dependency graph.
- `AppInfo` — version / build / display-name helpers read from
  `Info.plist`.

## Invariants

- **Composition root, not a feature.** This is the **only** module
  allowed to import all the others. Feature modules don't import
  `AppShell`.
- **Tokens stay in their stores.** `AppState` may *read* a session, but
  it never persists tokens itself — that's `FeatureAuth`'s job.
- **Provider-agnostic above the registry.** `AppState` resolves
  providers via `ProviderRegistry.provider(for:)`; nothing here
  switches on `ProviderKind` except for explicitly provider-specific UX
  (e.g. Plex Home-user PIN).
- **Profile-namespacing on switch.** Every per-user model must be
  rebuilt on profile change (`rebuildSettingsModels`) so settings,
  Trakt, and watched-state stay isolated.

## Where to look first

- `AppState.swift` — the orchestration entry point.
- `RootView.swift` + `MainTabView.swift` — the root navigation.
- `PlaybackEngineComposition.swift` — how libmpv is injected without
  leaking past this module.
