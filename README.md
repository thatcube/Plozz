<p align="center">
  <img src="Branding/plozz_logo.svg" alt="Plozz logo" width="128" />
</p>

<h1 align="center">Plozz</h1>

<p align="center">
  A free, open-source Apple TV app for your own media — connect a Jellyfin or Plex server and watch your library with native tvOS controls, Quick Connect sign-in, and resume support.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

## Features

Servers & sign-in:

- **Two providers, one experience** — connect a **Jellyfin** or **Plex** server; everything above the provider layer is identical, so Home, detail, and playback work the same either way.
- **Zero-config Jellyfin discovery** — finds servers on your LAN via the Jellyfin UDP auto-discovery protocol, with manual URL entry as a fallback.
- **Couch-friendly sign-in** — Jellyfin **Quick Connect** and Plex **Link** flows show a code, poll for completion, and handle expiry/timeout/cancel gracefully. No typing passwords with the remote.
- **Persistent session** — relaunch restores your session without re-login. Access tokens live in the **Keychain**; only non-secret metadata lives in `UserDefaults`, and tokens are never written to logs.

Browse & detail:

- **Home** — Continue Watching plus Latest / Recently Added rows.
- **Cinematic detail pages** — a full-bleed, high-resolution backdrop that fades seamlessly into the app background, with the show/movie logo, overview, ratings, and a Play/Resume button.
- **Series done right** — one stable, high-quality series backdrop with focus-driven season tabs and an episode rail; the hero text updates as you move focus without distracting backdrop swaps.
- **Watched state** — per-episode watched/unwatched badges and "mark watched up to here."
- **Trailers** — plays trailers attached to your library items, with an online (TMDb → YouTube) fallback when the server has none.

Playback:

- **`AVPlayer` + on-device engine routing** — direct play whenever possible; tricky formats (AV1, certain HEVC/10-bit, image-based PGS/VOBSUB subtitles, and more) are routed to a hybrid on-device engine automatically.
- **Resume** — playback position is restored and reported back to the server.
- **Audio & subtitle track selection** when available.
- **Full caption customization** — font, size, color, opacity, background, and edge style, applied through `AVPlayer` text style rules.

Appearance & robustness:

- **Themes** — System, Dark, OLED, and Light.
- **Profiles** — multiple local profiles with their own settings.
- **Robust states** — clear loading / empty / error states everywhere, including graceful handling of an offline or unreachable server.

## Architecture

Plozz is a Swift Package with one library per concern, consumed by a thin tvOS
app target generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

| Module | Responsibility |
| --- | --- |
| [`CoreModels`](Sources/CoreModels/README.md) | Domain models, `AppError`, `LoadState`, caption settings, and the **`MediaProvider`** protocol (the provider abstraction). |
| [`CoreNetworking`](Sources/CoreNetworking/README.md) | `HTTPClient`, `Endpoint`, URL normalization, and a secret-safe logger (`PlozzLog`). |
| [`CoreUI`](Sources/CoreUI/README.md) | Shared focusable components, theme, image cache, content-state views. |
| [`ProviderJellyfin`](Sources/ProviderJellyfin/README.md) | Jellyfin REST client, DTOs, device profile, and a `MediaProvider` implementation. |
| [`ProviderPlex`](Sources/ProviderPlex/README.md) | Plex client, DTOs, PIN/auth, connection resolver/selector, and a `MediaProvider` implementation. |
| [`ProviderTrailers`](Sources/ProviderTrailers/README.md) | Synthetic `MediaProvider` for online (YouTube) trailers, with stream extraction via YouTubeKit. |
| [`MetadataKit`](Sources/MetadataKit/README.md) | Keyless-first artwork & metadata enrichment (AniList, Kitsu, TVmaze, Deezer, MusicBrainz/CAA, Wikidata/Wikipedia) routed by content type with a persistent on-disk cache. Optional maintainer-hosted TMDb tier. |
| [`RatingsService`](Sources/RatingsService/README.md) | External ratings enrichment (OMDb optional key, keyless AniList) with on-disk cache. |
| [`TraktService`](Sources/TraktService/README.md) | Optional Trakt OAuth, scrobbling, and watched/sync helpers. |
| [`EngineMPV`](Sources/EngineMPV/README.md) | libmpv-backed `VideoEngine` conformer for codecs/containers AVPlayer can't decode (linked at the composition root). |
| [`TopShelfKit`](Sources/TopShelfKit/README.md) | Domain-to-snapshot mapping for the Top Shelf extension; writes to the shared App Group container. |
| [`FeatureDiscovery`](Sources/FeatureDiscovery/README.md) | LAN (UDP) discovery, server validation, server-picker UI, last-server persistence. |
| [`FeatureAuth`](Sources/FeatureAuth/README.md) | Quick Connect, Plex Link, password sign-in, the explicit **session state machine**, Keychain-backed account/session stores. |
| [`FeatureHome`](Sources/FeatureHome/README.md) | Home rows, item detail, series/season experience, online trailer fallback. |
| [`FeaturePlayback`](Sources/FeaturePlayback/README.md) | `AVPlayer` view model/view, engine routing, resume reporting, caption style rules, idle-sleep handling, diagnostics overlay. |
| [`FeatureSearch`](Sources/FeatureSearch/README.md) | Search view & view model, deduplication, search policy. |
| [`FeatureSettings`](Sources/FeatureSettings/README.md) | Settings (profiles, integrations, server, caption customization, preference detail). |
| [`FeatureProfiles`](Sources/FeatureProfiles/README.md) | Profile picker, editor, avatar/photo capture (household "Who's watching?"). |
| [`FeatureMusic`](Sources/FeatureMusic/README.md) | Music browsing, mini-player, queue/now-playing, background audio. |
| [`AppShell`](Sources/AppShell/README.md) | App state wiring, root navigation, profile selection, provider/registry composition. |

Each module's `README.md` documents its responsibility, public surface,
invariants (secrets, provider-agnosticism, platform portability), and the
right entry points to read first.

### Why a `MediaProvider` protocol?

Everything above the provider layer talks to the `MediaProvider` abstraction,
not to a specific backend. **Jellyfin** and **Plex** are each just a
`MediaProvider` conformer — Home, Playback, and navigation are written once and
work against either. Adding another backend means writing one new conformer, no
feature rewrites.

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
tools/setup-mpv.sh   # stage the gitignored libmpv/FFmpeg xcframeworks (instant)
xcodegen generate
open Plozz.xcodeproj
# Select the "Plozz" scheme and an Apple TV simulator, then Run.
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
`swift test` on Linux and an `xcodebuild` tvOS simulator build on macOS.

The libmpv-backed `EngineMPV` is intentionally excluded from the host
`swift test` graph: its binary xcframeworks are tvOS-only, and its sources
compile out behind `#if canImport(Libmpv)` on other platforms. It is covered by
the tvOS simulator/app build instead.

## Releasing to TestFlight & versioning

Distribution is automated with fastlane (App Store Connect API key auth — no
Apple ID/2FA needed). From a worktree, drop a gitignored `.env.fastlane` with
`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH` (see `.env.fastlane.example`),
then:

```bash
fastlane beta --env fastlane    # build + upload to TestFlight
fastlane build --env fastlane   # archive a signed .ipa locally, no upload
fastlane release --env fastlane # build + upload to the App Store
```

**Versioning** uses the standard two-number scheme, set in `project.yml`:

- **Marketing version** (`CFBundleShortVersionString`, e.g. `0.1`) — the public
  semver label. **Bump it manually** in `project.yml` when a release earns it
  (`0.1` → `0.2` → `1.0` → `1.0.1`). Pre-`1.0` signals in-development.
- **Build number** (`CFBundleVersion`) — **auto-incremented**; never edit it by
  hand. The `build` lane queries the latest build already on TestFlight, adds 1,
  and injects it via `CURRENT_PROJECT_VERSION` at archive time. This guarantees
  the strictly-increasing build number Apple requires for every upload, with no
  bookkeeping and no collisions across machines/worktrees. (The
  `CURRENT_PROJECT_VERSION: 1` default in `project.yml` only seeds plain
  `xcodebuild` / local device installs.)

tvOS **Brand Assets** (layered app icon + Top Shelf images) live in
`App/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets` and are
required for *any* App Store Connect upload, including TestFlight. The current
art is a placeholder — replace it before a public App Store release.

## Privacy & security

- Access tokens are stored in the Keychain; never in `UserDefaults` or logs.
- `PlozzLog` is the single logging entry point and never logs secrets.
- Local network usage is declared in `Info.plist` for LAN discovery.

## Roadmap

- **Overseerr** integration (request media).
- App Store polish: replace the placeholder tvOS **Brand Assets** app icon &
  Top Shelf image with final artwork before a public release.

## Donate

Plozz is free and open source, and it always will be. There's no paywall, no
ads, and no obligation to give anything.

If the app has been useful to you and you'd like to chip in toward its upkeep —
things like the Apple Developer Program fee and time spent maintaining it —
donations are welcome and genuinely appreciated. Anything is plenty, and not
donating is completely fine too.

[![Donate](https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/thatcube)

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time or recurring, whatever suits you.

## Credits & attribution

Plozz is an unofficial client and is not affiliated with, endorsed, or certified
by any of the services below.

- **The Movie Database (TMDB)** — some artwork and metadata is provided by the
  TMDB API. This product uses the TMDB API but is not endorsed or certified by
  TMDB. TMDB's marks and logos are trademarks of TMDB.

  <a href="https://www.themoviedb.org"><img src="https://www.themoviedb.org/assets/2/v4/logos/v2/blue_short-8e7b30f73a4020692ccca9c88bafe5dcb6f8a62a4c6bc55cd9ba82bb2cd95f6c.svg" alt="The Movie Database (TMDB)" height="24" /></a>

- **OMDb API** — optional IMDb ratings enrichment (requires your own OMDb key).
- **AniList** — keyless community scores for anime titles.
- **Plex** and **Jellyfin** — the media servers Plozz connects to. All library
  content, artwork, and ratings shown in the app are supplied by your own
  server. "Plex" and "Jellyfin" are trademarks of their respective owners.

## License

[MIT](LICENSE) © 2026 Brandon Moore

Not affiliated with or endorsed by Jellyfin or Plex, Inc.
