# Contributing to Plozz

Thanks for your interest in Plozz — a free, open source client for Jellyfin,
Plex, Emby, and local shares, on Apple TV, iPhone, and iPad. It's a small,
solo-maintained project, so this guide stays lightweight.

## Reporting bugs & requesting features

Everything starts with an issue. [**Open one**](https://github.com/thatcube/Plozz/issues/new/choose)
and pick a template:

- **🐞 Bug report** — captures what makes a bug fixable: steps to reproduce,
  expected vs actual, which backend is affected (Jellyfin / Plex / SMB), and your
  Plozz, tvOS, and Apple TV versions.
- **✨ Feature request** — a short form for problems worth solving.

Please search [existing issues](https://github.com/thatcube/Plozz/issues) first,
and never paste tokens, passwords, or credentialed server URLs.

## Development pipeline

The habit here: when a **real** bug turns up — a genuine defect, not a flaky
test — file a bug-report issue first, then fix it and reference the issue in your
commit or PR (e.g. `Fixes #123`). That keeps a searchable trail of what broke and
why. Keep it lightweight, but do file the issue.

## Building & running

### Requirements

- macOS with **Xcode 16+** (tvOS 18.0 deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

### Generate the project and run

The Xcode project is generated, not committed. Use the wrapper rather than
calling `xcodegen` directly — it also stamps the version and build number:

```bash
tools/generate-project.sh
open Plozz.xcodeproj
# Select the "Plozz" scheme (or "PlozziOS") and a simulator, then Run.
```

### Build and deploy to a device

```bash
tools/deploy-tv.sh --build-only   # compile, don't install
tools/deploy-tv.sh                # build, install, launch on an Apple TV
tools/deploy-ios.sh --ipad        # iPad
```

To install a branch's build **alongside** the canonical app rather than
replacing it, add `--branded`:

```bash
tools/deploy-tv.sh  --branded
tools/deploy-ios.sh --ipad --branded
```

That installs `com.thatcube.Plozz.<branch-slug>` as a separate app. It signs
against stripped entitlements, so it has no cloud sync and won't inherit your
servers — see [`docs/per-branch-builds.md`](docs/per-branch-builds.md).

### Tests

```bash
tools/run-tests.sh [SchemeName]
```

Tests run on a tvOS Simulator. **`swift test` is not usable here** — the
playback engine's frameworks are tvOS-only.

### Screenshots

Plozz photographs itself by driving a Simulator; there's no capture card and no
device to keep plugged in. The marketing and App Store shots, and the ones
embedded in the README, all come from that pipeline:

```bash
tools/capture-shots.sh            # Apple TV -> build/shots/
tools/readme-shots.sh             # web-sized README images
```

The full explanation, including the traps, is in
[`docs/screenshots.md`](docs/screenshots.md).

### Performance debugging

If the app feels laggy, or you see blank artwork or memory crashes on device,
[`docs/performance-debugging.md`](docs/performance-debugging.md) is an on-device
playbook using the watchdog and Instruments (`xctrace`).

### Localization

All UI copy is served from one app-owned String Catalog. Adding a string means
writing it in Swift, running `tools/l10n-sync.py`, and committing both. The
rules — and the traps — are in [`docs/localization.md`](docs/localization.md).

Plozz ships complete UI and permission-prompt catalogs for **36 languages**,
including Arabic/Hebrew RTL layouts and full Slavic plural forms. How
translations are produced, reviewed, structurally gated, and corrected is in
[`docs/translations.md`](docs/translations.md).

### Releasing to TestFlight

Distribution is automated with fastlane (App Store Connect API key auth). Drop a
gitignored `.env.fastlane` with `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_KEY_PATH`
(see `.env.fastlane.example`), then:

```bash
fastlane beta --env fastlane    # build + upload to TestFlight
fastlane build --env fastlane   # archive a signed .ipa locally, no upload
fastlane release --env fastlane # build + upload to the App Store
```

**Versioning** (`project.yml`): bump the **marketing version**
(`CFBundleShortVersionString`) by hand; the **build number** is auto-incremented
from the latest TestFlight build at archive time — never edit it manually.

App icons, in-app logos, and tvOS **Brand Assets** are generated from
`App/Resources/Assets.xcassets/PlozzLogo.imageset/plozz_logo.svg` with
`python3 tools/generate_brand_assets.py`. The tvOS App Store and Top Shelf
assets live under `App/Resources/Assets.xcassets/…brandassets`.

## Architecture

Plozz is a Swift Package with one library per concern, consumed by thin app
targets generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

| Module | Responsibility |
| --- | --- |
| [`CoreModels`](Sources/CoreModels/README.md) | Domain models, `AppError`, `LoadState`, caption settings, and the **`MediaProvider`** protocol (the provider abstraction). |
| [`CoreNetworking`](Sources/CoreNetworking/README.md) | `HTTPClient`, `Endpoint`, URL normalization, and a secret-safe logger (`PlozzLog`). |
| [`CoreUI`](Sources/CoreUI/README.md) | Shared focusable components, theme, image cache, content-state views. |
| [`ProviderJellyfin`](Sources/ProviderJellyfin/README.md) | Shared Jellyfin/Emby MediaBrowser client, DTOs, compatibility shims, device profile, and `MediaProvider` implementation. |
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
abstraction rather than a specific backend. Jellyfin and Emby intentionally share
one conformer so their supported features remain in lockstep.

## The dual-provider invariant

Plozz treats **Jellyfin and Plex as co-equal, first-class backends**. Any
contribution that touches data, playback, auth, metadata, search, or navigation
must work for **both** — neither is a "phase 2" afterthought. Everything above
the provider layer talks to the `MediaProvider` protocol rather than a specific
backend; see [Architecture](#architecture). If a change can only work
for one backend, call that out explicitly in the issue/PR.

## Coding norms

Keep changes focused and match the surrounding style. That's about it — open an
issue if you're unsure whether something's a good fit before investing a lot of
time.
