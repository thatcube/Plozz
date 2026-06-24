# FeatureProfiles

The "Who's watching?" launch picker and the profile editor — Plozz's
household multi-user UI on top of `CoreModels.ProfileStore`.

## Responsibility

- `ProfilePickerView` — the launch / "Switch Profile" picker. Shows the
  household's profile tiles (avatar + name), focusable, with an "add
  profile" tile that opens the editor. `AppShell.ProfileSelectionView`
  hosts this for both the launch flow and Settings → Switch Profile.
- `ProfileEditorView` — create / rename / restyle a profile (name,
  `avatarSymbol` SF Symbol, color from `ProfileTileColor` palette,
  account subset, Plex Home-user mapping).
- `ProfileAvatarView` — renders a profile tile from its
  SF-Symbol-based avatar + color index. Pure presentation; the avatar
  palette resolution lives here (not in `CoreModels`, which stays
  Foundation-only).
- `ProfileTileColor` — the colour palette and the deterministic
  `colorIndex → Color` resolution used by avatar / tile / picker.
- `ProfilePhotoCandidate` — value type backing photo-based avatar
  inputs (tvOS only supports SF Symbols today; photo support is
  currently stubbed/disabled but the type is kept for future expansion).

## Invariants

- **Non-secret only.** Profiles are non-secret metadata; tokens belong
  to `FeatureAuth.AccountStore`.
- **Default profile is special.** Stable id
  `ProfileStore.defaultProfileID` (`com.plozz.profile.default`); `nil`
  settings namespace; cannot be removed. Don't break the upgrade path.
- **SF-Symbol avatars only on tvOS.** Photo upload is not currently a
  shipping feature — the picker UI must reflect that.
- **Profile-aware everywhere.** Any feature reading per-user state
  (settings, watched, recommendations) must scope through the active
  profile id from `CoreModels.ProfilesModel`.

## Where to look first

- `ProfilePickerView.swift` + `ProfileEditorView.swift` — the two UI
  surfaces.
- `ProfileTileColor.swift` — color palette resolution.
- `CoreModels/ProfileStore.swift` — the persistence layer this UI edits.
