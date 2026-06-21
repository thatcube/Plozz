# Music Library Support — Design & UX Proposal

**Status:** Proposal / investigation (no behavioural change shipped)
**Scope:** Add support for browsing and playing a **music** library (artists,
albums, tracks, playlists, genres) from Plex **or** Jellyfin, alongside the
existing TV & Movies experience.
**Owning constraint:** Everything above the provider layer talks to the
`MediaProvider` protocol in `CoreModels`, never to Jellyfin/Plex directly. Any
music support must preserve that seam and must stay **invisible to video-only
users**.

---

## 1. Why music, and the core UX tension

A polished 10-foot music experience is a genuine differentiator: most third-party
tvOS Jellyfin/Plex clients treat music as an afterthought (no background audio,
no now-playing screen, no mini-player). Done well, "great music too" is a reason
to choose Plozz.

But the audience splits three ways and we must serve all three without
compromise:

| User | What they have / want | Failure mode to avoid |
| --- | --- | --- |
| **Video-only** | No music library, or no interest | Music UI clutters Home, adds an empty tab, confuses them |
| **Music-only** | Mostly an audio library | Forced through a video-first UI; no persistent playback |
| **Both** | Mixed libraries | Music and video fight for the same rows and tabs |

**Design north star:** music presence is **detected, not configured**. If no
account exposes a music library, Plozz looks and behaves exactly as it does
today. If music *is* present, it appears in a self-contained surface that a
video-centric user can ignore, and that a music-centric user can live in.

---

## 2. How music fits the existing `MediaProvider` abstraction

### 2.1 What exists today

`MediaProvider` (`Sources/CoreModels/MediaProvider.swift`) is a `Sendable`
protocol with library browsing, paged `items(in:kind:page:)`, search,
`playbackInfo(for:)` → `PlaybackRequest`, progress reporting, subtitles and
`imageURL`. The domain types are deliberately video-shaped:

- `MediaItemKind` = `movie | series | season | episode | video | folder |
  collection | unknown` — **no audio kinds**.
- `MediaItem` carries `seasonNumber`, `episodeNumber`, `resumePosition`,
  `playedPercentage`, `posterURL`/`backdropURL` — episode/movie semantics.
- `PlaybackRequest` resolves a single stream URL and audio/subtitle tracks for an
  `AVPlayer` full-screen presentation.
- Providers map native shapes onto these types: Jellyfin
  `kind(forCollectionType:)` only handles `movies`/`tvshows`/`boxsets`
  (everything else → `.folder`); Plex `kind(forSectionType:)` only maps
  `movie`/`show`. **A music library today falls through to `.folder` /
  `.unknown` and is effectively inert.**

Both backends already speak music natively — they just aren't mapped:

- **Jellyfin:** `CollectionType == "music"`; item types `MusicArtist`,
  `MusicAlbum`, `Audio`; `/Artists`, `/Albums`, `Playlists`, `/MusicGenres`
  endpoints; instant-mix and "Audio" stream via `/Audio/{id}/universal`. The app
  already advertises audio `DirectPlayProfile`s and a
  `MusicStreamingTranscodingBitrate` in `JellyfinCapabilityProfile`, so the
  transcode/direct-play plumbing for audio is *already present*.
- **Plex:** section `type == "artist"`; metadata types `artist` (grandparent),
  `album` (parent), `track` (leaf); `/library/sections/{id}/all?type=8|9|10`
  (8 = artist, 9 = album, 10 = track); playlists via `/playlists`; transcode via
  `/music/:/transcode/universal`.

### 2.2 The design decision: extend, don't overload

There are two ways to model music:

**Option A — overload the existing types.** Add `.artist/.album/.track/.playlist`
to `MediaItemKind` and reuse `MediaItem`/`MediaProvider`. *Rejected:* it pollutes
every existing `switch item.kind` across FeatureHome/Search/Playback with audio
cases they must now handle, blurs poster-vs-album-art and episode-vs-track
semantics, and risks breaking the strict `MediaProvider` conformance contract
that 6 parallel agents and two providers depend on. It is the opposite of
"invisible to video users."

**Option B — additive, capability-gated music seam (recommended).** Leave
`MediaProvider` and `MediaItem` **untouched**. Introduce a *separate, optional*
music capability that a provider may conform to, plus dedicated music value types:

```
CoreModels (new files only)
├─ MusicModels.swift        MusicArtist, MusicAlbum, MusicTrack,
│                           MusicPlaylist, MusicGenre, MusicItemKind
├─ MusicProvider.swift      protocol MusicProvider (a.k.a. MusicCapable)
│                           + AudioPlaybackRequest
└─ ProviderCapability.swift ProviderCapability OptionSet + helpers
```

Key properties:

1. **Non-breaking.** `MediaProvider`'s signatures don't change, so
   `ProviderJellyfin` and `ProviderPlex` keep compiling untouched. Music support
   is added later by each provider *opting in* in its own module:
   `extension JellyfinProvider: MusicProvider { … }` — a pure addition.
2. **Capability-gated.** Feature code asks `provider as? MusicProvider` (or reads
   a `ProviderCapability` set). A provider/account with no music library reports
   no music capability, and **every music surface is conditionally absent**. This
   is the mechanism that keeps music invisible for video-only users.
3. **Aggregation-aware.** Music libraries flow through the same multi-account
   aggregation seam as video (`AggregatedLibrary`, `sourceAccountID` tagging), so
   a user with two servers gets a merged music view, and a tapped album routes
   back to its owning provider exactly like a tapped movie does today.
4. **Mirrors the existing optional-capability pattern.** The codebase already
   uses protocol-extension defaults for optional behaviour (remote subtitle
   search/download default to no-ops). `MusicProvider` is the same idea at a
   larger granularity.

### 2.3 Music domain model (new value types)

Music's hierarchy (Artist → Album → Track, plus flat Playlists and Genres) is a
poor fit for the season/episode-shaped `MediaItem`, so model it explicitly:

- `MusicArtist { id, name, artworkURL, albumCount?, genres }`
- `MusicAlbum  { id, title, artistName, artistID?, year?, artworkURL,
                 trackCount?, totalDuration? }`
- `MusicTrack  { id, title, albumTitle?, artistName?, albumID?, trackNumber?,
                 discNumber?, duration?, artworkURL }`
- `MusicPlaylist { id, title, artworkURL, trackCount?, totalDuration? }`
- `MusicGenre  { id, name }`
- `MusicItemKind = artist | album | track | playlist | genre` (separate enum, so
  `MediaItemKind` is never touched).

`AudioPlaybackRequest` is the audio analogue of `PlaybackRequest`: a resolved
stream URL, a `playSessionID` for progress reporting, the owning track, and an
ordered **queue** of tracks (album/playlist context) so next/previous works.
Progress reporting can reuse the existing `PlaybackProgress`/`reportPlayback`
plumbing on `MediaProvider`, or a parallel music method — see §6.

---

## 3. UX options: music-only vs video-only vs both

Three candidate shells, evaluated against the three audiences.

### Option 1 — A dedicated, conditionally-present **Music tab**

Add a 4th top-level tab (`Home · Search · Music · Settings`) that appears **only
when at least one account exposes a music library**.

- **Video-only:** tab never appears → zero clutter. ✅
- **Music-only:** Music tab is a full browse-and-play surface; they live there.
  Home still shows their (possibly empty) video rows, which is mildly redundant
  but harmless. ◐
- **Both:** clean separation — video on Home, music on Music. The mental model
  ("two libraries, two tabs") matches how Plex/Jellyfin organise the data. ✅
- **Cost:** moderate. New tab + navigation stack; reuses CoreUI components.
- **Risk:** low. Fully additive; nothing about the video path changes.

### Option 2 — Unified Home with music rows

Inject music rows ("Recently Added Music", "Artists", "Albums") into the existing
aggregated Home alongside video rows, gated by the Home-libraries visibility
checklist that already exists (`HomeLibraryVisibility`).

- **Video-only:** no music libraries → no music rows. ✅ (relies on the existing
  opt-out visibility model, which already hides libraries.)
- **Music-only:** music is buried *below* empty/secondary video rows; no
  dedicated home base; no obvious "all my music" entry. ✗
- **Both:** Home becomes long and mixes fundamentally different interaction
  models (pick-and-play-a-movie vs queue-an-album). Poster grids and album grids
  interleave awkwardly. ◐
- **Cost:** low-moderate, but most of it lands in **FeatureHome** (owned by
  another agent) and couples music tightly to the video Home.
- **Risk:** medium — highest blast radius on shared, contended modules.

### Option 3 — Top-level **mode switch** (Video ⇄ Music)

A single switch (profile-style or a segmented control on a landing screen) flips
the whole app between a Video mode and a Music mode, each with its own tabs.

- **Video-only / Music-only:** if only one library type exists, **skip the switch
  entirely** and boot straight into that mode. ✅✅ — this is the cleanest
  single-purpose experience for both extremes.
- **Both:** powerful and uncluttered per-mode, but adds a navigation gesture and
  some "where am I" overhead; switching modes mid-session is heavier than tabbing.
  ◐
- **Cost:** high — touches AppShell root navigation and state.
- **Risk:** medium-high; largest structural change.

### Recommendation

**Ship Option 1 (conditional Music tab) as the primary model, and fold in the
best idea from Option 3** — *auto-detect single-purpose libraries*:

- **No music anywhere →** today's app, unchanged. No tab, no settings, no hint.
- **Music + video →** the Music tab appears; Home/Search stay video-first. Users
  who don't care never open the tab.
- **Music-only account →** the Music tab is present *and* Plozz biases toward it
  (e.g. selects the Music tab on launch, and the now-mostly-empty video Home can
  be de-emphasised). The user effectively gets a music app.

Why this wins: it's the most **additive** (lives almost entirely in new
files + AppShell tab wiring, avoiding contended FeatureHome internals), it makes
music **opt-in by data** (presence of a library), and it scales from "pure music
appliance" to "everything in one app" with a single conditional. The mode-switch
(Option 3) can be revisited later if "both" users find the tab model limiting —
nothing here precludes it.

A small **Settings** affordance ("Show Music tab: Auto / Always / Never",
defaulting to **Auto**) gives power users an override without burdening anyone
else. "Auto" = the detection rule above.

---

## 4. Navigation model

Within the Music tab, a `NavigationStack` mirroring `HomeTab`/`SearchTab`:

```
Music (landing)
├─ Recently Added            → Album detail
├─ Artists   → Artist detail → Album detail → Track list (in album)
├─ Albums    → Album detail  → Track list
├─ Playlists → Playlist      → Track list
└─ Genres    → Genre         → Albums/Artists in genre
```

- **Landing:** a few aggregated rows (Recently Added, Top/Recent Artists,
  Playlists) plus entry tiles for the full Artists / Albums / Playlists / Genres
  grids — consistent with the existing Home "rows + drill-in" pattern and reusing
  CoreUI focusable cards.
- **Artist detail:** hero artwork + album grid (and optionally "Appears On").
- **Album / Playlist detail:** track list with per-track focus; **Play** (from
  top) and **Shuffle**; selecting a track starts the album/playlist as the queue
  from that track.
- **Grids** reuse the paged `items(in:kind:page:)` design via a music-specific
  paged fetch (artists/albums can be large), keyed by `MusicItemKind` the same
  way video libraries page by `MediaItemKind`.
- **Genres** are a flat filter that re-enters Albums/Artists.
- **Search:** music results can be merged into the existing Search tab as
  additional result sections ("Artists", "Albums", "Tracks") *only when a music
  capability is present*, or kept inside the Music tab's own search. Initial
  phase keeps search **inside** the Music tab to avoid editing FeatureSearch.

---

## 5. Now-playing, mini-player, and background audio

This is where music diverges most from the current `AVPlayer` **full-screen,
foreground-only, one-shot** video flow (`FeaturePlayback`), and where the real
engineering lives.

### 5.1 Audio differs from video in three structural ways

1. **It plays in the background / with the screen off.** Video is always
   full-screen and foreground; audio must keep playing while the user browses
   other screens or the TV's screensaver kicks in.
2. **It has a queue.** A movie is one item; an album/playlist is an ordered list
   with next/previous, shuffle, and repeat.
3. **It needs a persistent surface.** You can't occupy the whole screen the way
   video does, because the user keeps browsing while listening → a **mini-player**
   plus a full **Now Playing** screen.

### 5.2 A dedicated audio playback engine (new, separate from the video player)

Introduce an `AudioPlaybackController` (app-scoped, `@MainActor`, observable)
that is **independent** of `PlayerViewModel` (which stays video-only and
untouched):

- Owns an `AVQueuePlayer` (or an `AVPlayer` + manual queue) for gapless-ish
  next/previous.
- Holds the current `AudioPlaybackRequest` queue, index, shuffle/repeat state.
- Is created once and injected into the environment, so the mini-player and Now
  Playing screen observe the same instance from anywhere in the app.

**tvOS background audio requirements (the part the video flow doesn't do):**

- **Audio session category.** Configure `AVAudioSession` with
  `.playback` category (and `setActive(true)`). This is what lets audio continue
  when the view isn't full-screen and survive the screensaver. The current video
  player never sets this because full-screen video implies it.
- **Now Playing info.** Populate `MPNowPlayingInfoCenter.default().nowPlayingInfo`
  with title/artist/album, artwork (`MPMediaItemArtwork`), duration and elapsed
  time, so the tvOS system Now Playing / Control Center surface and the lock-style
  info are correct.
- **Remote command center.** Wire `MPRemoteCommandCenter`: play, pause,
  toggle, next/previous track, and change-playback-position, so the Siri Remote's
  play/pause and the system transport controls drive the queue.
- **Info-plist / capability.** Audio background mode must be permitted for tvOS
  background playback (declare the background audio capability in the app target
  config; XcodeGen `project.yml`). *(Config change only; tracked as a phase task,
  not part of the additive CoreModels scaffold.)*

### 5.3 Mini-player + Now Playing screen

- **Mini-player:** a slim persistent bar (artwork thumb + title/artist + a focus
  affordance) that appears at the bottom of the Music tab (and optionally
  app-wide) **only while audio is loaded**. Focusing it and pressing select opens
  the full Now Playing screen. It disappears when playback is stopped/cleared.
- **Now Playing screen:** full artwork, track/artist/album, scrubber, transport
  (prev / play-pause / next), shuffle & repeat toggles, and an "Up Next" queue
  list. Built from CoreUI primitives.
- **Focus engine note:** the mini-player must participate in the tvOS focus
  system without stealing focus from the browse grid — it should be reachable by
  swiping down to it, not grab focus on appearance.

### 5.4 Reuse vs. new

| Concern | Reuse | New |
| --- | --- | --- |
| Stream resolution / transcode decision | Provider device profiles (audio profiles already exist) | `AudioPlaybackRequest` |
| Progress / resume reporting | `PlaybackProgress` + `reportPlayback` plumbing | music call sites |
| Player object | — | `AudioPlaybackController` (`AVQueuePlayer`) |
| Background audio / now-playing / remote | — | audio session + `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` |
| UI components | CoreUI cards/focus/theme | mini-player + Now Playing views |

---

## 6. Phased implementation plan

**Phase 0 — Foundation (this PR, additive scaffold only).**
New `CoreModels` files: music value types, `MusicProvider`/`MusicCapable`
protocol, `AudioPlaybackRequest`, and a `ProviderCapability` set. **No** change to
`MediaProvider`, no provider edits, no UI. Everything compiles and `swift test`
passes. Ships dark — nothing user-visible.

**Phase 1 — Read-only music browse (one provider).**
Map music collection/section types in **one** provider (Jellyfin first: it
already has audio device profiles). Conform `JellyfinProvider` to `MusicProvider`
in its own module; add a paged music fetch. Build the conditional **Music tab**
with Artists/Albums/Playlists/Genres grids and detail screens. No playback yet —
or playback that just plays a single track full-bleed using the existing engine
as a stopgap. Detection rule wired: tab present only when a music library exists.

**Phase 2 — Real audio playback + Now Playing + background audio.**
`AudioPlaybackController` with `AVQueuePlayer`, audio session, now-playing info,
remote commands, and the background-audio capability. Mini-player + Now Playing
screen. Queue semantics (play album/playlist, next/prev, shuffle, repeat).
Progress reporting via the existing seam.

**Phase 3 — Second provider + parity.**
Conform `PlexProvider` to `MusicProvider`; verify aggregation merges music across
accounts. Add the Settings "Show Music tab: Auto/Always/Never" override and any
music-only launch biasing.

**Phase 4 — Polish & differentiators.**
Instant-mix / "play artist radio", lyrics if available, genre stations, Top Shelf
music entries, continue-listening, search integration into the main Search tab,
gapless tuning, per-track scrubbing refinements.

**Deferred / explicitly out of scope initially:** editing playlists from the TV,
offline/download, multi-room/cast, visualisers, music videos as a hybrid type.

---

## 7. Risks & mitigations

- **Scope creep into contended modules.** FeatureHome/Search/Settings are owned
  by other agents. *Mitigation:* keep Phase 0–1 in new files + AppShell tab
  wiring; defer Search/Settings integration to later phases with coordination.
- **`MediaProvider` contract breakage.** Two providers and several features
  depend on it. *Mitigation:* never change its signatures; music is a *separate*
  optional protocol (capability-gated), exactly like the existing no-op subtitle
  defaults.
- **Background audio correctness on tvOS.** Audio session + now-playing + remote
  wiring is fiddly and easy to get subtly wrong (audio stops on screensaver,
  stale now-playing info). *Mitigation:* isolate it in `AudioPlaybackController`
  with focused tests around state transitions; validate on-device early (single
  shared Apple TV — coordinate the device lock).
- **Focus-engine conflicts** from a persistent mini-player. *Mitigation:* the
  mini-player must not auto-grab focus; reachable by directional navigation only.
- **Empty/odd libraries.** A "music" library with only audiobooks, or a video
  user who happens to have one stray music library. *Mitigation:* detection is
  per-capability and the Settings override (Auto/Always/Never) covers edge cases;
  Auto can additionally suppress the tab when the music library is trivially small.
- **Large libraries.** Artists/albums/tracks can be huge. *Mitigation:* reuse the
  existing paged-browse design (`PageRequest`/`MediaPage` analogue) from day one.

---

## 8. Summary

Model music as an **additive, capability-gated seam** in `CoreModels`
(`MusicProvider` + music value types) that never touches the `MediaProvider`
contract, surface it through a **conditional Music tab** that only appears when a
music library is detected (with an Auto/Always/Never override), and give audio a
**dedicated playback engine** with a mini-player, Now Playing screen, and proper
tvOS background-audio (audio session + now-playing info + remote commands) — all
delivered in phases that keep video-only users' experience byte-for-byte
unchanged. A minimal, non-breaking Phase 0 scaffold accompanies this proposal in
new `CoreModels` files (see `MusicModels.swift`, `MusicProvider.swift`,
`ProviderCapability.swift`).
