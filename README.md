<p align="center">
  <img src="App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg" alt="Plozz logo" width="128" />
</p>

<h1 align="center">Plozz</h1>

<p align="center">
  A free and open source native Apple TV app for Jellyfin or Plex servers.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/EKfReNMu"><img src="docs/assets/testflight-button.png" alt="Join the Plozz public beta on TestFlight" width="210" /></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" alt="License: GPL-3.0" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

## Try the beta

Plozz is in **public beta** on TestFlight. [**Join the beta →**](https://testflight.apple.com/join/EKfReNMu) to install it on your Apple TV (tvOS 17 or later) and stream from your own Jellyfin or Plex server.

## Features

Servers & sign-in:

- **Jellyfin and Plex** — one experience over either backend; Home, detail, and playback work the same.
- **Multiple servers, one library** — Together or separate - you can connect multiple Jellyfin and Plex servers; Everything optionally merges together.
- **Auto-discovery** — finds Jellyfin servers on your LAN (UDP) automatically, with manual URL entry as a fallback.
- **Remote-free sign-in** — Jellyfin **Quick Connect** and Plex **Link**: enter a code, no password typing.
- **Persistent session** — relaunch restores your login. Tokens live in the Keychain and are never logged.

Browse & detail:

- **Home** — Continue Watching plus Latest / Recently Added.
- **Detail pages** — full-bleed backdrop, logo, overview, ratings, and a Play/Resume button.
- **Series** — focus-driven season tabs and an episode rail, with per-episode watched badges and "mark watched up to here."
- **Trailers** — plays library trailers, with a TMDb → YouTube fallback when the server has none.
- **Music** — browse artists and albums with a mini-player, queue, and background audio.

Playback:

- **Direct play first** — `AVPlayer` plays what it can; tricky formats (AV1, some HEVC/10-bit, image-based PGS/VOBSUB subtitles) route to an on-device engine automatically.
- **Resume** — position is restored and reported back to the server.
- **Skip intros & credits** — skip buttons appear automatically from your server's media segments.
- **Track selection** — audio and subtitles when available.
- **Caption customization** — font, size, color, opacity, background, and edge style.

Appearance:

- **Themes & display size** — System, Dark, OLED, and Light, plus adjustable interface sizing.
- **Night mode** — highly adjustable settings to warm and dim the display automatically to protect your circadian rhythm
- **Profiles** — all settings are per-profile, allowing you to customize the experience to your own preferences while grandma can do as she pleases

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

Each module's `README.md` documents its responsibility, public surface, and
invariants. Everything above the provider layer talks to the **`MediaProvider`**
abstraction rather than a specific backend, so Jellyfin and Plex are each just a
conformer — adding another backend means one new conformer, no feature rewrites.

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

```bash
swift test
```

The logic modules are platform-portable, so `swift test` runs on any Swift
toolchain — no simulator. UI and the libmpv-backed `EngineMPV` compile out behind
`#if canImport(...)` guards and are covered by the tvOS simulator/app build
instead. CI runs `swift test` on Linux and an `xcodebuild` tvOS build on macOS.

### Performance debugging

If the app feels laggy or you see blank artwork / memory crashes on device, see
[`docs/performance-debugging.md`](docs/performance-debugging.md) — an on-device
playbook using the watchdog and Instruments (`xctrace`).

## Releasing to TestFlight

Distribution is automated with fastlane (App Store Connect API key auth). Drop a
gitignored `.env.fastlane` with `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`
(see `.env.fastlane.example`), then:

```bash
fastlane beta --env fastlane    # build + upload to TestFlight
fastlane build --env fastlane   # archive a signed .ipa locally, no upload
fastlane release --env fastlane # build + upload to the App Store
```

**Versioning** (`project.yml`): bump the **marketing version**
(`CFBundleShortVersionString`, e.g. `0.1` → `0.2`) by hand; the **build number**
is auto-incremented from the latest TestFlight build at archive time — never edit
it manually.

tvOS **Brand Assets** (app icon + Top Shelf images) live under
`App/Resources/Assets.xcassets/…brandassets` and are required for any upload. The
current art is a placeholder — replace it before a public App Store release.

## Roadmap

- **Overseerr** integration (request media).
- iOS and/or iPadOS app depending on demand

## Donate

Plozz is free and open source, with no paywall, ads, or obligation. If it's
useful to you, donations toward upkeep
are welcome — and not donating is completely fine.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time or recurring.

## Credits & attribution

Plozz is an unofficial client and is not affiliated with, endorsed, or certified
by any of the services below.

- **AetherEngine** — on-device playback engine (FFmpeg demux → VideoToolbox
  decode) by Vincent Herbst, LGPL-3.0 with an App Store exception.
  [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine).
- **libmpv / FFmpeg** — a decode-only, LGPL-3.0 build backs the optional
  `EngineMPV` (see [`NOTICE.md`](NOTICE.md)).
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

[GPL-3.0](LICENSE) (with an App Store Exception) © 2026 Brandon Moore
