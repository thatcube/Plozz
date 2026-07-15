# FeatureDiscovery

LAN auto-discovery of Jellyfin and Emby servers (Plozz's "drop the box on the
network and Plozz finds it" experience) plus the server-picker UI and
last-server persistence. Plex relies on `plex.tv` for server enumeration
in `ProviderPlex`, not LAN UDP.

## Responsibility

- `ServerDiscovering` — the platform-agnostic protocol; an
  `AsyncStream<MediaServer>` of unique servers, capped by a timeout.
  Lives in its own portable file so view-models can depend on the
  abstraction without importing the `Network`-based implementation.
- `JellyfinDiscoveryParser` — parses the shared Jellyfin/Emby UDP discovery responses
  into `MediaServer` value types (independent of the transport so it's
  unit-testable on Linux).
- Concrete Apple-platform implementation — uses `Network` framework UDP
  multicast/broadcast on tvOS to find servers on the local subnet.
- `ServerPickerView` + `ServerPickerViewModel` — the focusable tvOS UI
  that streams discovered servers, supports manual URL entry, validates
  the URL via the appropriate provider, and surfaces clear loading /
  empty / error states.
- `LastServerStore` — remembers the most-recently-used server so relaunch
  jumps straight to sign-in instead of re-discovering.

## Invariants

- **No tokens stored here.** Only non-secret server metadata
  (`MediaServer`).
- **Every provider represented.** Server selection must produce a
  `MediaServer` whose `provider: ProviderKind` is set correctly — the
  rest of the app branches on that.
- **Network errors degrade visibly.** Discovery timing out is normal and
  yields the manual-URL fallback path, not an error toast.
- **Compiles without UI.** The parser + abstraction live in plain Swift;
  views are guarded by `#if canImport(SwiftUI)`.

## Where to look first

- `ServerDiscovering.swift` — the protocol every consumer should use.
- `JellyfinDiscoveryParser.swift` — UDP payload → `MediaServer`.
- `ServerPickerViewModel.swift` — the orchestration & validation loop.
