# SwiftUI hot-reload on a physical Apple TV (InjectionNext)

Edit a SwiftUI view in VS Code/Copilot, save, and watch it redraw on the TV in
~300–400 ms with **no rebuild, no reinstall, no relaunch**. This took a long
time to figure out; this doc is the fast path. Follow it top to bottom.

## TL;DR (what makes it work)

1. **InjectionNext.app** runs on the Mac, listening on `*:8887`, with its
   "Injection Host" set to the Mac's Tailscale IP. A Debug-only build script
   embeds `iOSInjection.bundle` into the app and bakes that host into Info.plist.
2. The app dlopens that bundle at launch; the bundle dials the host over TCP and
   waits for recompiled dylibs.
3. Build with `PLOZZ_INJECT=1` so targets get `-interposable`, batch mode, and
   `-v` (frontend command lines) — InjectionNext replays those to recompile a
   single edited file.
4. Each screen view declares `@ObserveInjection var inject` + `.enableInjection()`
   so it actually **redraws** when symbols rebind.
5. Deploy ritual must KEEP `Testing.framework`; only rename the one duplicate-id
   overlay. Deleting Testing.framework is what caused the old "No Client".

All of it is **inert in release** — `@ObserveInjection`/`.enableInjection()`
are no-ops outside DEBUG and the bundle/flags only exist under `PLOZZ_INJECT`.

## One-time machine setup

- InjectionNext.app installed in `/Applications`.
- Mac + Apple TV on the same Tailscale tailnet. Set InjectionNext's **Injection
  Host** to the Mac's tailnet IP (e.g. `100.81.93.19`). macOS firewall: allow
  InjectionNext.
- Device: `DE913871-CC2D-5F75-B4F2-0D6F44AA30DE`.

## Build + deploy ritual (copy/paste)

```bash
cd <worktree>
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"   # SPM resolve fix
tools/setup-mpv.sh                                          # stage mpv xcframeworks
tools/generate-project.sh                                  # xcodegen
PLOZZ_INJECT=1 xcodebuild -project Plozz.xcodeproj -scheme Plozz \
  -configuration Debug -destination 'platform=tvOS,id=DE913871-CC2D-5F75-B4F2-0D6F44AA30DE' \
  clean build

APP="$(ls -d ~/Library/Developer/Xcode/DerivedData/Plozz-*/Build/Products/Debug-appletvos/Plozz.app)"
ID=16DA09E19E64F0975B592AF15A3F3AD21F328528
# Fix the ONE duplicate bundle id — do NOT delete Testing.framework.
CT="$APP/Frameworks/_Testing_CoreTransferable.framework"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.apple.dt.swift-testing.overlay.CoreTransferable' "$CT/Info.plist"
codesign --force --sign $ID --timestamp=none "$CT"
# Re-sign app with its .xcent (NEVER --deep — it strips entitlements).
XCENT="$(dirname "$(dirname "$APP")")/../Intermediates.noindex/Plozz.build/Debug-appletvos/Plozz.build/Plozz.app.xcent"
codesign --force --sign $ID --entitlements "$XCENT" --timestamp=none --generate-entitlement-der "$APP"
xcrun devicectl device install app --device DE913871-CC2D-5F75-B4F2-0D6F44AA30DE "$APP"
xcrun devicectl device process launch --device DE913871-CC2D-5F75-B4F2-0D6F44AA30DE com.thatcube.Plozz
```

Then in VS Code, save an edit to any wired screen → it reloads on the TV. No
redeploy unless you change a different target (Package.swift, project.yml).

## Verify it connected

Launch attached and watch logs:
`xcrun devicectl device process launch --console --device <ID> com.thatcube.Plozz`
Expect: `🔥 Connecting to INJECTION_HOST ...` → `arm64 AppleTVOS connected` →
`🔄 Recompiling` → `✅ Hot reload complete - Rebound N symbols`. (`--console`
kills the app when the shell ends.)

## Making a screen hot-reloadable

A feature package's view redraws only if it opts in:
1. Add `.product(name: "Inject", package: "Inject")` to the target deps in `Package.swift`.
2. In the screen: `import Inject`, `@ObserveInjection var inject`, and
   `.enableInjection()` on the outermost view in `body`.
Children redraw with the wired parent — only screen-level views need it. Already
wired: Home, Auth, Discovery, Music, Playback, Profiles, Search, Settings.

## Gotchas (the time-sinks)

- **"No Client" = bundle didn't dlopen, not a network problem.** The deploy
  ritual must keep `Testing.framework` + `_Testing_*`; only rename the
  duplicate-id `_Testing_CoreTransferable`. Deleting Testing.framework breaks
  `libXCTestSwiftSupport.dylib`'s `@rpath/Testing.framework/Testing` load.
- SPM packages must be batch/incremental (not whole-module) or single-file
  recompile fails — handled by the `PLOZZ_INJECT` loop in Package.swift.
- Package files need frontend command lines → `-v` is in the inject loop;
  `EMIT_FRONTEND_COMMAND_LINES` is project-wide Debug in project.yml.
- Re-sign with `--deep` strips entitlements; use the `.xcent` form above.
- A view sometimes needs a 2nd save to trigger the watcher; that's normal.
