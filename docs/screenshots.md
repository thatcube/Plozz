# Marketing and App Store screenshots

Plozz photographs itself. The screenshots on the marketing site and the ones
uploaded to App Store Connect are produced by driving a Simulator, not by
pointing a capture card at an Apple TV.

```sh
./tools/capture-shots.sh              # drive Simulators, write build/shots/*.png
node tools/appstore-shots.mjs         # compose build/appstore/<platform>/*.png
```

And to push the results at the marketing site:

```sh
cd ../plozz-website && npm run shots  # copy the changed masters, re-encode
```

---

## Why this exists

The masters were captured by hand off a real Apple TV over HDMI. That is the
reason they went stale: refreshing one screenshot meant setting up hardware, so
nobody did it, and the site shipped a build that was several releases old.

A Simulator screenshot comes from the framebuffer, so it is exactly 3840x2160
with no capture card, no HDMI, and no device to leave plugged in.
`xcrun simctl io screenshot` is lossless PNG.

## Why it needs no credentials

The app is seeded with an NFS share that is exported to `*` with no auth, and
Plozz enriches share content from the keyless metadata tier — so a bare folder
of files becomes a library with real artwork, overviews, ratings and cast. That
is what makes these look like marketing shots rather than a file browser.

Seeding goes through `ScreenshotSeed`, which calls the same
`didConfigureNFSShare` the onboarding UI calls and then completes the first-run
steps. No UI driving is needed to reach Home.

## How a screen is reached

**Not by pressing the remote.** That was the first design and it could not be
made to work: tvOS focus moves one cell at a time, the number of presses depends
on what the library happens to contain, and the shelf reorders as soon as
something is watched. A run that walks focus does not fail loudly — it quietly
photographs the wrong title.

Instead the app is asked for a screen *by name*. The host writes a line into a
file in the app's own container and the app searches its real libraries and
pushes the value a tap would have pushed:

```
detail?title=Oppenheimer
person?title=Oppenheimer&person=Cillian%20Murphy
library?name=TV
play?title=The%20Office&at=600
probe?title=Dune          # answers with the titles the library actually has
```

See `Sources/AppShell/ScreenshotDirector.swift`. It is DEBUG-only and inert
unless the capture environment asked for it.

A file rather than the `plozz://shots/…` URL it also accepts, because tvOS puts
an "Open in Plozz?" confirmation in front of `simctl openurl` and there is no way
to dismiss a system alert without the remote-driving this exists to avoid.

The app acks each request once it has **reached** the screen, not once it has
parsed it, so a title the library does not have is reported rather than
silently photographing whatever was still on screen.

## Things that will bite you

- **Signing must stay on.** With `CODE_SIGNING_ALLOWED=NO` the app ships without
  entitlements, the Keychain returns `errSecMissingEntitlement` (-34018), the
  media-share credential vault cannot initialise, and the share fails to save —
  presenting as "Something went wrong", which looks nothing like a signing
  problem.
- **The first run scans the whole share** (~10.5k items) and takes a long while.
  That work persists in the Simulator's container, so later runs start already
  populated. Do **not** pass `--reset` unless you mean it.
- **A file share cannot be re-sorted.** `CatalogReadQueries` pages with a fixed
  `ORDER BY sort_title`, so the library grid is always alphabetical and setting
  the sort menu's stored choice changes only its label. The library shot browses
  TV Shows for this reason: the Movies library leads with a file that has no
  artwork and sorts before "A".
- **The player's transport bar auto-hides**, and a file-driven run supplies no
  input to reveal it. `ScreenshotSeed.holdPlayerControlsIfRequested` holds it
  open for a capture run; the subtitle shot deliberately waits for that hold to
  lapse so the subtitle is photographed against the picture instead of under the
  bar.

## App Store panels

`tools/appstore-shots.mjs` composes the raw captures into submission-ready
panels at the sizes App Store Connect asks for:

| Platform | Size | Orientation |
| --- | --- | --- |
| Apple TV | 3840 x 2160 | landscape |
| iPhone 6.9" | 1320 x 2868 | portrait |
| iPad 13" | 2064 x 2752 | portrait |

The 6.9" iPhone and 13" iPad sizes are the only ones required — Apple scales
them down to every smaller device in the same family. Ten panels per platform is
the maximum; the lists in the script stay under it.

Panels are composed rather than uploaded raw because a 3840x2160 frame of a
detail page is legible on a laptop and unreadable in the 200px strip a shopper
actually scrolls past, so each panel pairs the capture with one line saying what
it is. Apple permits this — the requirement is that a screenshot depicts the
real app, and these are the app photographing itself against a real library.

They are laid out in HTML and rendered by headless Chrome rather than
composited, so they can share the marketing site's background, its blue and its
corner radii, and not read as a different product.

Captures are flattened to sRGB with no alpha at capture time, because App Store
Connect rejects a screenshot that carries an alpha channel at all.
