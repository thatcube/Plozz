# Per-branch builds (`--branded`)

Install a branch's build on a real device **side-by-side with the canonical app**,
so you can test it without losing the app you actually use.

```sh
tools/deploy-tv.sh  --branded          # Apple TV
tools/deploy-ios.sh --ipad --branded   # iPad
tools/deploy-ios.sh --iphone --branded # iPhone
```

That's the whole workflow. The scripts handle project regeneration, signing,
install, launch, and restoring the canonical project state on exit.

## What you get

The app is named and identified from the current git branch:

| branch | app name | bundle id |
| --- | --- | --- |
| `thatcube-localization` | Plozz localization | `com.thatcube.Plozz.localization` |
| `thatcube-new-player` | Plozz new-player | `com.thatcube.Plozz.new-player` |

The `thatcube-` prefix is stripped and the rest is slugified (lowercased,
non-alphanumerics to `-`, capped at 24 characters).

## What a branded build deliberately gives up

A per-branch build uses a **brand-new App ID**, and a new App ID cannot
auto-provision the canonical app's special capabilities. So branded builds sign
against stripped entitlements:

- `App/Resources/Plozz.branded.entitlements` (tvOS)
- `App/PlozziOS/PlozziOS.branded.entitlements` (iOS)

Both are empty. The practical consequences:

| Capability | Effect on a branded build |
| --- | --- |
| iCloud / CloudKit | **No cloud sync.** Config stays device-local. |
| Push notifications | No silent CloudKit wake-ups (tvOS already ships this way). |
| Associated Domains (iOS) | `applinks:plozz.app` routes to the canonical app. |
| App Group (tvOS) | Top Shelf stays empty. |
| User Management (tvOS) | Falls back to the normal per-user keychain. |

**The most visible consequence: a branded build will not inherit your servers or
profiles, so you will sign in again.** That is intended isolation — the branded
app has its own container and cannot disturb your real setup — not a bug.

Everything above degrades rather than fails. If you need a capability to actually
work, test on the canonical app instead.

## Troubleshooting

### `0xe8008012` — "This provisioning profile cannot be installed on this device"

The profile doesn't include your device's UDID. `tools/deploy-ios.sh` now catches
this **before** installing and prints which UDID is missing, because the raw
error names neither the device nor the profile.

Usual cause is a stale cached profile. In order:

1. Connect and unlock the device, then re-run. The script builds against the
   concrete target device, which is normally enough to make Xcode refresh.
2. `rm -rf ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles`
3. Confirm the device is registered on the developer portal.

Root cause, for the curious: with a *generic* destination (`generic/platform=iOS`)
xcodebuild has no target device to provision for, so `-allowProvisioningUpdates`
could hand back a wildcard profile containing the wrong device set. For the
canonical app id an all-devices profile already existed, so this never showed up;
a fresh per-branch App ID exposed it immediately.

### The app crashes instantly on launch

Should be fixed — but the shape is worth recognising, because more than one API
behaves this way. `CKContainer(identifier:)` does **not** return an error when the
iCloud entitlement is missing; it **traps** (`EXC_BREAKPOINT`/`SIGTRAP`). A
`do/catch` around a later call never runs, because the crash happens earlier, on
container construction.

`CloudConfigSyncService` now checks the entitlement (read from the embedded
provisioning profile) before touching CloudKit. If you add code that consumes a
stripped capability, guard it the same way — assume the API traps rather than
throws until proven otherwise.

### It builds but doesn't install

`--build-only` skips installing. Also check the device is awake and unlocked;
`install-verified.sh` retries and confirms by querying the device, since the
install command's exit code is unreliable over wireless.

## Cleaning up

Delete the branded app from the device like any other app. Nothing else to undo —
the scripts restore the canonical project and `Info.plist`s on exit (including
after a failure), so `git status` stays clean.
