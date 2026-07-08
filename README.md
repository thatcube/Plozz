<p align="center">
  <img src="App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg" alt="Plozz logo" width="128" />
</p>

<h1 align="center">Plozz</h1>

<p align="center">
  A free forever, open source, native Apple TV app for Jellyfin, Plex, and local shares.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/EKfReNMu"><img src="docs/assets/testflight-button.png" alt="Join the Plozz public beta on TestFlight" width="264" /></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" alt="License: GPL-3.0" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS-black.svg?logo=apple" alt="Platform: tvOS" /></a>
  <a href="https://github.com/sponsors/thatcube"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

## Try the beta

Plozz is in **public beta** on TestFlight. [**Join the beta**](https://testflight.apple.com/join/EKfReNMu) to install it on your Apple TV right now.

## Reporting bugs & requesting features

Found a bug or have an idea? [**Open an issue**](https://github.com/thatcube/Plozz/issues/new/choose) and pick a template — 🐞 **Bug report** or ✨ **Feature request**. For the full contribution flow (the file-an-issue-then-fix habit, dev setup, and the dual-provider expectation), see [**CONTRIBUTING.md**](CONTRIBUTING.md).

## Unique Features

- **Multiple servers, one library.** Merge all of your content into one library across plex, jellyfin and local share (SMB only) servers.
- **Sync watch history across all servers** - Optionally sync your watch history across every server that's connected. Watch it on Plex, it will sync that same watch status to Jellyfin (if Jellyfin has the same title).
- **Mark as watched** - Mark an entire season as watched or "up to here" to quickly update watch history.
- **Watched & unwatched indicators** — Choose a watched checkmark or an unwatched corner badge (Infuse / classic-Plex style) on your posters, across Plex, Jellyfin and SMB shares.
- **Trakt, AniList, MyAnimeList, Simkl, and Last.fm** - Full support for every tracker across your movies, tv, anime, and music.
- **Seerr integration** - Connect a seerr account and request media from directly within the search or hero of the app.
- **Highly customizable interface** - Change the theme of the entire app (light, dark, OLED). Change the density of media, optionally show hero content, change the navigation style. 
- **Jellyfin, Plex, and local shares (SMB)**
- **Circadian mode** - Automatically warm and dim the display at set times to help you sleep (only at the app level)
- **Subtitle customization** — Vastly customize the subtitles directly in the player. Change font, size, color, opacity, background, font weight, HDR brightness, shadow, position.
- **Dual subtitle support** - Turn on 2 different subtitle tracks at the same

- **Auto-discovery** — Automatically detect jellyfin servers, seerr servers
- **Remote-free sign-in** — Jellyfin **Quick Connect** and Plex **Link** supported

- **Profiles** — Native Apple TV profile support - all settings are per-profile and your profile selection is remembered based on the Apple TV profile that was last used
- **(Almost) All video formats supported** - Powered by [AetherEngine](https://github.com/superuser404notfound/AetherEngine), an open source engine that fully supports HDR, Dolby Vision, AV1, virtually everything.[View the full list](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/formats.md).

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
| [`MetadataKit`](Sources/MetadataKit/README.md) | Keyless-first artwork & metadata enrichment (AniList, Kitsu, TVmaze, Deezer, MusicBrainz/CAA, Wikidata/Wikipedia) routed by content type with a persistent on-disk cache. Bundled TheTVDB tier + optional maintainer-hosted TMDb tier. |
| [`RatingsService`](Sources/RatingsService/README.md) | External ratings enrichment (OMDb optional key, keyless AniList) with on-disk cache. |
| [`TraktService`](Sources/TraktService/README.md) | Optional Trakt OAuth, scrobbling, and watched/sync helpers. |
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
xcodegen generate
open Plozz.xcodeproj
# Select the "Plozz" scheme and an Apple TV simulator, then Run.
```

### Run the unit tests

```bash
swift test
```

The logic modules are platform-portable, so `swift test` runs on any Swift
toolchain — no simulator. UI modules compile out behind `#if canImport(...)`
guards and are covered by the tvOS simulator/app build instead. CI runs
`swift test` on Linux and an `xcodebuild` tvOS build on macOS.

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
`App/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets` and are
required for any upload. They're generated in-repo — no separate tooling or the
plozz-website repo needed. The source art is the pixel-art TV logo at
`App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg`; to change the
icon, edit that SVG and re-run:

```bash
python3 tools/generate_brand_assets.py   # needs cairosvg, numpy, Pillow
```

This writes all 13 PNGs and their `Contents.json` into the `.brandassets`
bundle: both layered (parallax) app-icon stacks plus the Top Shelf and Top Shelf
Wide images, over a grey pixel-textured background tinted from the logo's own
blues.

## Roadmap
- Dedicated iOS music app (Mozz)
- iOS and/or iPadOS Plozz app depending on demand

## Donate

Plozz will always be free and open source, with no paywall, ads, or obligation. If it's
useful to you, donations toward upkeep
are welcome — and not donating is completely okay.

**[Donate via GitHub Sponsors](https://github.com/sponsors/thatcube)** — one-time or recurring.

## Credits & attribution

Plozz is an unofficial client and is not affiliated with, endorsed, or certified
by any of the services below.

- **AetherEngine** — on-device playback engine (FFmpeg demux → VideoToolbox
  decode) by Vincent Herbst, LGPL-3.0 with an App Store exception.
  [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine).
  Its bundled FFmpeg is a decode-only, LGPL-3.0 build (see [`NOTICE.md`](NOTICE.md)).
- **The Movie Database (TMDB)** — some artwork and metadata is provided by the
  TMDB API. This product uses the TMDB API but is not endorsed or certified by
  TMDB. TMDB's marks and logos are trademarks of TMDB.

  <a href="https://www.themoviedb.org"><img src="https://www.themoviedb.org/assets/2/v4/logos/v2/blue_short-8e7b30f73a4020692ccca9c88bafe5dcb6f8a62a4c6bc55cd9ba82bb2cd95f6c.svg" alt="The Movie Database (TMDB)" height="24" /></a>

- **[TheTVDB](https://thetvdb.com)** — some metadata and artwork is provided by
  TheTVDB. Please consider adding missing information or subscribing at
  [thetvdb.com](https://thetvdb.com). This product uses the TheTVDB API but is
  not endorsed or certified by TheTVDB.

  <a href="https://thetvdb.com/subscribe"><img src="https://www.thetvdb.com/images/attribution/logo1.png" alt="TheTVDB" height="24" /></a>

- **OMDb API** — optional IMDb ratings enrichment (requires your own OMDb key).
- **AniList** — keyless community scores for anime titles.
- **Plex** and **Jellyfin** — the media servers Plozz connects to. All library
  content, artwork, and ratings shown in the app are supplied by your own
  server. "Plex" and "Jellyfin" are trademarks of their respective owners.

## License

[GPL-3.0](LICENSE) (with an App Store Exception) © 2026 Brandon Moore
