# Plizz

**Plizz** is a free, open-source **tvOS** client for [Jellyfin](https://jellyfin.org).
Discover a Jellyfin server on your local network, sign in from your couch with
**Quick Connect**, browse your library, and play media with resume support —
all using native tvOS controls and the Apple TV focus engine.

> Phase 1 (this MVP) is **Jellyfin only**. Plex and Overseerr are planned for
> later phases behind the same provider abstraction.

## Features (Phase 1 MVP)

- **Zero-config server discovery** — finds Jellyfin servers on your LAN via the
  Jellyfin UDP auto-discovery protocol, with manual URL entry as a fallback.
- **Quick Connect sign-in** — TV-friendly flow that shows a code, expiry and
  retry, polls for completion, and handles timeout/cancel gracefully. No typing
  passwords with the remote.
- **Persistent session** — relaunch restores your session without re-login.
  Access tokens are stored in the **Keychain**; only non-secret metadata lives
  in `UserDefaults`. Tokens are never written to logs.
- **Home** — Continue Watching and Latest / Recently Added rows.
- **Item detail + playback** — `AVPlayer`-based playback with **resume
  position** restore/update and audio/subtitle track selection when available.
- **Full caption customization** — font, size, color, opacity, background and
  edge style, applied through `AVPlayer` text style rules.
- **Robust states** — clear loading / empty / error states everywhere,
  including graceful handling of an offline / unreachable server.

## Architecture

Plizz is a Swift Package with one library per concern, consumed by a thin tvOS
app target generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

| Module | Responsibility |
| --- | --- |
| `CoreModels` | Domain models, `AppError`, `LoadState`, caption settings, and the **`MediaProvider`** protocol (the provider abstraction). |
| `CoreNetworking` | `HTTPClient`, `Endpoint`, URL normalization, and a secret-safe logger (`PlizzLog`). |
| `ProviderJellyfin` | Jellyfin REST client, DTOs, and a `MediaProvider` implementation. |
| `FeatureDiscovery` | LAN (UDP) discovery, server validation, server-picker UI, last-server persistence. |
| `FeatureAuth` | Quick Connect service, explicit **session state machine**, Keychain-backed `SessionStore`. |
| `FeatureHome` | Home rows + item detail. |
| `FeaturePlayback` | `AVPlayer` view model/view, resume reporting, caption style rules. |
| `FeatureSettings` | Settings, including caption customization. |
| `CoreUI` | Shared focusable components and theme. |
| `AppShell` | App state wiring and root navigation. |

### Why a `MediaProvider` protocol?

Everything above the provider layer talks to the `MediaProvider` abstraction,
not to Jellyfin directly. Adding **Plex** in Phase 2 means writing a new
`MediaProvider` conformer — no changes to Home, Playback, or navigation.

### Session state machine

Auth/session state is explicit (`launching → selectingServer → authenticating →
authenticated → failed`) with a pure `reduce` function that is unit-tested,
keeping UI free of ad-hoc boolean flags.

## Building & running

### Requirements

- macOS with **Xcode 16+** (tvOS 17.0 deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Generate the project and run

```bash
xcodegen generate
open Plizz.xcodeproj
# Select the "Plizz" scheme and an Apple TV simulator, then Run.
```

### Run the unit tests

The logic modules are platform-portable and run on any Swift toolchain (no
simulator needed):

```bash
swift test
```

On Linux/macOS without UI frameworks, the SwiftUI/AVKit/UIKit views compile out
behind `#if canImport(...)` guards, so `swift test` exercises the models,
networking, discovery, provider mapping, and auth logic directly. CI runs
`swift test` on Linux and an `xcodebuild` tvOS build on macOS.

## Privacy & security

- Access tokens are stored in the Keychain; never in `UserDefaults` or logs.
- `PlizzLog` is the single logging entry point and never logs secrets.
- Local network usage is declared in `Info.plist` for LAN discovery.

## Roadmap

- **Phase 2:** Plex provider, Overseerr (request media).
- App Store polish: tvOS **Brand Assets** app icon & Top Shelf image (the MVP
  ships without placeholder art so it builds clean for the simulator).

## License

Plizz is open source and free. See [`LICENSE`](LICENSE).
