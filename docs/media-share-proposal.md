# Local Media Share Support — Design Proposal

**Status:** Still just a design for the provider/library side, BUT — the scary part
(Phase 1, getting SMB to actually play on the Apple TV) now works. A file off my
NAS plays end to end: playback, seeking forward/back, guest login and a real
password login. It goes through AetherEngine's normal `SMBIOReader` path, so
nothing weird. The thing that ate a bunch of time — libsmb2 throwing `EPERM` on
tvOS — is figured out and fixed by not using libsmb2 (see **§5.1**). Everything
below is still the plan for the third, second-class backend next to Plex/Jellyfin.
**Scope:** Let a user point Plozz at a "dumb" file share (NAS over SMB2/3, or a
WebDAV/HTTP file server) and get a browsable, playable library with artwork,
metadata, resume, and watched state — without a Plex/Jellyfin server in the path.
**Owning constraint:** Everything above the provider layer talks to the
`MediaProvider` protocol in `CoreModels`, never to a backend directly. A media
share must preserve that seam and stay **invisible to users who don't add one**.
Plex and Jellyfin remain the first-class, "king" experiences; a share is a
deliberately smaller, opt-in citizen.

---

## 1. The core problem

A real media server (Plex/Jellyfin) hands us, for free, the things the whole app
is built around: a typed library tree, rich metadata + artwork, a search index,
**server-side transcoding**, and a durable **watch-state store** that syncs across
clients. A plain share provides none of that — only a directory of bytes.

So "add a media share" is really: **replace the two services a server gives us —
a metadata/library index and a place to store watch state — with on-device
equivalents**, while reusing everything else Plozz already does above the provider
seam (Home fan-out, cross-source identity/merge, playback routing, the watch
outbox).

This is exactly the model Infuse uses for SMB/DLNA shares: on-device TMDb/TheTVDB
scraping for metadata, and an app-owned library DB for watched/resume state synced
across devices via iCloud. No server involved.

---

## 2. How a share fits the existing `MediaProvider` abstraction

Adding a backend is *designed* to be cheap: one `MediaProvider` conformer, one
`ProviderKind` case, one `registry.register(...)` line in
`AppState.makeDefaultRegistry()`. That stays true here. What's different from
Plex/Jellyfin is that the conformer is backed by **local stores** instead of a
network API.

`ProviderShare` conforms to:
- `MediaProvider` — library browsing, item detail, search, `playbackInfo`,
  `imageURL`. Backed by `ShareLibraryStore` (below), not a server.
- `WatchStateProviding` + `ResumeStateWriting` — but writes land in a **local**
  `ShareWatchStore`, never a network call.
- `CapabilityReporting` — advertises `.video` only.

Everything the protocol already makes optional — trailers, remote-subtitle
search/download, server skip-intro/credits segments, trickplay scrub previews —
is simply **not** implemented and inherits the protocol's safe empty/no-op
defaults. The `MediaProvider` contract was effectively pre-designed for a partial
provider like this.

```mermaid
flowchart TB
    UI[Home / Detail / Search / Player<br/>talk only to MediaProvider] --> PS

    subgraph HH[Household-global · user-independent Keychain + App Group]
      Cfg[(ShareConfigStore<br/>hosts, shares, paths, protocol)]
      Cred[[SMB/WebDAV credentials<br/>user-independent Keychain]]
    end

    subgraph PROF[Per Plozz profile]
      Watch[(ShareWatchStore<br/>SQLite in App Group · source of truth<br/>played + resume position)]
      Watch <-->|CKRecord tagged profileID<br/>scoped to current Apple ID| CK[(CloudKit private DB)]
    end

    Cfg --> PS
    Watch --> PS
    subgraph PS[ProviderShare : MediaProvider + WatchStateProviding + ResumeStateWriting + CapabilityReporting]
      Scan[ShareScanner<br/>walk SMB/WebDAV tree] --> Ident[Identifier<br/>filename / .nfo → title, year, SxE]
      Ident --> Meta[MetadataKit → TMDb / TVDb<br/>ids + overview + cast + artwork]
      Meta --> Lib[(ShareLibraryStore<br/>SQLite in App Group)]
    end

    PS -->|playbackInfo → smb:// via IOReader<br/>or https:// via load url| AE[AetherEngine + AetherEngineSMB]
    PS -.->|item carries providerIDs.tmdb| Merge[Existing MediaItemIdentity / Merger<br/>merges share ↔ Plex/Jellyfin twins]
    Watch <--> Outbox[Existing WatchMutationOutbox<br/>twin fan-out + Trakt/Simkl mirror]
```

---

## 3. Metadata & identification

- **Reuse `MetadataKit`.** It already resolves a TMDb id from a title/year
  `MetadataQuery` and returns artwork. We add a "fetch full metadata" path
  (overview, cast, production year, genres, season/episode mapping, episode
  stills) on top of the existing id resolution.
- **The genuinely hard, new part is the `Identifier`** — parsing scene-named
  files into a query: `Movie Name (2021).mkv`,
  `Show/Season 01/Show - S01E02 - Title.mkv`, etc., plus `.nfo` sidecars when
  present. This is where Infuse has invested years; v1 handles the common
  conventions and provides a manual **"Fix Match"** affordance for misses.
- **Payoff for merge:** once scraped, each item carries `providerIDs["tmdb"]`
  (and IMDb/TVDb where resolvable), so it flows through the **existing**
  `MediaItemIdentity`/`MediaItemMerger` engine unchanged and **merges with the
  user's Plex/Jellyfin copies** of the same title with no new merge logic.

---

## 4. Watch state — the part that reuses the most

Today watch state is **100% server-backed**: `WatchStateProviding` /
`ResumeStateWriting` write *through* a provider to a server, and
`WatchMutationOutbox` / `WatchStateReconciler` fan one play out to every server
plus external trackers (Trakt/Simkl/AniList/MAL). There is **no local watch
store** yet.

Design:
1. Add `ShareWatchStore` — a **local SQLite DB in the App Group** holding played
   flags + resume positions. This is the **source of truth**.
2. `ProviderShare`'s `WatchStateProviding`/`ResumeStateWriting` writes land in
   `ShareWatchStore` instead of a network call. A local write never fails, so a
   share is a trivially reliable outbox target.
3. `ProviderShare.continueWatching()` / `latest()` are **synthesized** from
   `ShareWatchStore` (+ scanner mtime for "recently added"), since there's no
   server to compute them.
4. Because the outbox addresses targets as "accountID → provider that conforms to
   the watch protocols," the share becomes **just another fan-out target**. When a
   share title merges with a Plex/Jellyfin twin (same TMDb id), watching it on
   either side converges both — and Trakt/Simkl mirroring comes along — using
   machinery that already ships. *(Build-time check: `WatchMutationApplier` in
   `AppShell` must resolve a share account the same way it resolves Plex/Jellyfin;
   likely a small addition.)*

### 4.1 CloudKit sync + the profile/Apple-ID scoping tension

Chosen approach: **CloudKit + a local SQLite mirror (App Group) as the source of
truth**, CloudKit syncs the mirror.

The subtlety is scoping. Plozz uses the `com.apple.developer.user-management`
entitlement (`runs-as-current-user-with-user-independent-keychain`):
- **Per Apple TV system user (≈ per Apple ID):** `UserDefaults` + default Keychain
  are partitioned. All current per-profile settings live here.
- **Household-global (shared across system users):** account sign-ins **and** the
  Plozz profile set, kept in the user-independent Keychain.

CloudKit's private DB is inherently **per-Apple-ID** and cannot span two Apple IDs
(a hard platform rule — Infuse has the same limit). So we split the two concerns:

| Concern | Scope | Storage |
| --- | --- | --- |
| **Share config + credentials** | **Household-global** | user-independent Keychain (creds) + App-Group `ShareConfigStore` |
| **Watch state** (played / resume) | **Per Plozz profile** | per-profile `ShareWatchStore` (App Group) + CloudKit |

CloudKit records are written to the **current Apple ID's private DB** and tagged
with a **`profileID`** field so multiple profiles under one Apple ID stay separate.

Resulting behavior:

| Situation | Outcome |
| --- | --- |
| One Apple ID, multiple profiles | One iCloud DB; histories separated by `profileID`; each profile syncs across that Apple ID's devices |
| Separate Apple IDs (separate system users / devices) | Separate iCloud DBs → separate share history per Apple ID. Share **config** stays household-global on a given box, so the NAS isn't re-added |
| Everyone shares one Apple ID, different profiles | Shared DB, separate histories via `profileID` |

**Known edge (v1 tolerates, documents):** a profile object is household-global
(one `profileID`) but sync is per-Apple-ID. If the *same* profile is used under
*two different* Apple IDs on one Apple TV, that `profileID` accumulates two
divergent histories in two iCloud accounts, so its Continue Watching appears to
change when the box's active Apple ID changes. In practice a person uses one
Apple ID; this only bites households that share profiles across Apple IDs on one
device, and "your own history per Apple ID" is defensible/privacy-positive. A
later "bind this profile's sync to a home Apple ID" toggle could remove it, but
that's out of scope for v1.

---

## 5. Playback

- Add the upstream **`AetherEngineSMB`** product to the `EnginePlozzigen` target
  and give `PlozzigenVideoEngine` a `load(source: .custom(SMBIOReader(...)))` path
  next to the existing `load(url:)` one. One catch: on tvOS the actual byte-source
  can't be AMSMB2/libsmb2 (it just doesn't work — §5.1), so we hand `SMBIOReader` a
  `NWConnection`-based reader instead.
- **WebDAV / HTTP shares need nothing new** — the core engine reads range-readable
  HTTP(S) via its custom AVIO + `URLSession`, so those play through `load(url:)`.
- tvOS requires `NSLocalNetworkUsageDescription` + the local-network entitlement
  to reach a LAN share.
- **Only the Plozzigen/AetherEngine engine can consume a custom `IOReader`**; the
  AVPlayer-native path cannot. On a custom reader the native path re-muxes to
  cleartext fMP4 on the loopback cache (fine for at-rest content).
- **No transcoding.** Playback is limited to what the device + AetherEngine can
  decode on-device (which is wide — MKV, HEVC/AV1, DoVi, Atmos, DTS/TrueHD
  bridged). There is **no server-side downscale fallback**, so a very high-bitrate
  4K file over a slow remote link may buffer with no graceful degradation.
- SMB support is **read-only, NTLMv2 / guest auth (no Kerberos)**.

### 5.1 The tvOS SMB saga (why we don't use libsmb2)

Writing this down because I lost a good chunk of time to it and I don't want to
re-learn it later — or have someone "helpfully" swap the transport back.

**The symptom.** AetherEngine's `AetherEngineSMB` ships one SMB transport,
`SMBConnection`, built on [AMSMB2](https://github.com/amosavian/AMSMB2) (which
wraps the C library `libsmb2`). On macOS it's fine. On the Apple TV, the very
first `connectShare` blows up with:

```
Error Domain=NSPOSIXErrorDomain Code=1 "Operation not permitted"
```

Guest, anonymous, real credentials — didn't matter, same `EPERM` every time. The
error string is empty too, because AMSMB2 tears down the libsmb2 context before it
reads the message, so all you get is the bare errno. Super helpful.

**Stuff I chased down and ruled out** (so nobody repeats it):

- Tailscale — my Mac and the ATV are both on it. Turned it off on the ATV, no
  change. Not it.
- Credentials — guest vs anonymous vs a real user, all `EPERM`. Not it.
- Local-network privacy consent — an `NWConnection` to the NAS reaches `.ready`
  fine, so consent isn't the blocker.
- The `com.apple.developer.networking.multicast` entitlement — added it out of
  desperation, did nothing.
- Threading — ran the probe on the main thread, a detached `Thread`, and a GCD
  global queue. All the same.
- DNS / socket options — `getaddrinfo`, `TCP_NODELAY`, `SO_REUSEADDR`, `SO_LINGER`,
  all fine.

**The thing that actually settled it.** I hand-rolled a plain BSD socket in the
app — `socket()` → `connect()` → `send()` → `recv()` — and fired a real SMB2
NEGOTIATE at the NAS on port 445. It came straight back with a valid SMB2 reply
(`recv() 77 bytes`, magic `fe 53 4d 42`), on all three thread contexts. So tvOS
is NOT blocking SMB. The platform is totally happy to talk SMB2. It's libsmb2
specifically that trips the `EPERM` — some socket call it makes that tvOS doesn't
like, and the difference is invisible from up here because the context gets nuked.

Turns out this is a known, never-fixed libsmb2-on-iOS/tvOS thing — AMSMB2 issues
[#32](https://github.com/amosavian/AMSMB2/issues/32),
[#63](https://github.com/amosavian/AMSMB2/issues/63),
[#64](https://github.com/amosavian/AMSMB2/issues/64), all the same "Operation not
permitted", all open. The fix in #64 was literally "I switched SMB libraries."

**What we switched to.** [kishikawakatsumi/SMBClient](https://github.com/kishikawakatsumi/SMBClient)
— pure Swift, MIT, zero C deps, SMB2, and it does its networking over
`NWConnection` (Network.framework) instead of raw sockets. That's the exact path
I already proved works on the device. It exposes a `fileSize` + `read(offset:
length:)` API, which is basically what AetherEngine's `ByteRangeSource` protocol
wants, so it drops right in behind the engine's existing `SMBIOReader` with no
engine changes to prototype it. We wrote a ~90-line `NWSMBByteSource` (a
`ByteRangeSource` conformer) and pointed `PlozzigenVideoEngine.makeSMBSource` at
it.

**Does it actually work?** Yeah. Tested on the Apple TV against my Unraid box
(a real ~85-min 1080p MKV):

| | guest share | password share (NTLMv2) |
| --- | --- | --- |
| connect + login + tree-connect | ✅ | ✅ |
| plays, bytes decoding, playhead moving | ✅ | ✅ |
| seek forward (~2555s in) | ✅ ~0.6s | ✅ ~0.9s |
| seek near the end (~4600s) | ✅ ~1.1s | ✅ ~1.2s |
| seek backward (~511s) | ✅ ~1.2s | ✅ ~1.6s |

The backward seek is the one I cared about most — that's the muxer path that used
to wedge (AetherEngine PR #94), and here it just lands and keeps playing. Seeks
are what prove the byte-source can do random-access reads at big offsets, not just
stream front-to-back.

**Where this should live.** Long-term this belongs *in AetherEngine*, not Plozz.
The engine already owns the whole SMB story (`ByteRangeSource`, `SMBIOReader`, the
URL parsing) — only that one `SMBConnection` class is the broken libsmb2 bit.
Swapping it for an `NWConnection`-backed reader fixes tvOS for the engine and
anyone else using it, and as a bonus it's MIT instead of libsmb2's LGPL and it's
Swift you can actually fork if the maintainer disappears. So the plan is: prove it
in Plozz (done), then upstream the reader into `AetherEngineSMB` and let Plozz go
back to just using the engine's own class.

*(The Plozz-side `NWSMBByteSource` + the `PLOZZ_SMB_TEST_URL` spike are temporary
scaffolding to prove all this — they come out once the fix is upstream.)*

---

## 6. UI / onboarding (second-class citizen)

The merged add-account flow (`AppShell/AddAccountView`) is already a clean
`ProviderKind?` chooser with two `ProviderBrandMark` cards (Jellyfin, Plex). The
share slots in as:
- A **small secondary button below the two cards** ("Add a local media share"),
  matching the intended "Plex or Jellyfin, or (small share button)" hierarchy.
- A new `ProviderKind.mediaShare` case (+ `displayName`, + a `ProviderBrandMark`
  symbol) and a `case .mediaShare` branch in `AddAccountView` that pushes a new
  `AddShareView` (protocol SMB/WebDAV, host, share, path, credentials).
- One new `registry.register(.mediaShare) { ... }` line.

---

## 7. What's reused vs. new vs. lost

| | |
| --- | --- |
| **Reused free** | Home rows, Search, detail pages, playback (incl. SMB via `AetherEngineSMB`), **cross-source merge with Plex/Jellyfin**, and — pending the applier tweak — **cross-server watch sync via the existing outbox** + Trakt/Simkl mirror |
| **New code** | `ProviderShare`, `ShareScanner`, `Identifier`, `ShareLibraryStore`, `ShareWatchStore` (+ CloudKit mirror), `ShareConfigStore`, `AddShareView`, a `.mediaShare` kind, a MetadataKit "full metadata" path |
| **Lost vs. a server** | On-the-fly transcoding (device-decode only, no downscale fallback), server skip-intro/credits, trickplay scrub previews, "official" server metadata, other-users' watched state |

---

## 8. Phasing

1. **Playback spike** — add `AetherEngineSMB` + a `load(source:)` path + tvOS
   entitlements; prove SMB bytes → DoVi/Atmos pipeline end-to-end on the Apple TV.
   ✅ **Done** — plays + seeks, guest and password, on-device. Had to swap the SMB
   transport off libsmb2 to get there (see §5.1); that fix wants upstreaming into
   AetherEngine.
2. **Provider + library** — `ProviderShare`, scanner, identifier, MetadataKit
   full-fetch, `ShareLibraryStore`; browse and play a real share (no watch state).
3. **Watch state (local)** — `ShareWatchStore` + outbox target wiring + twin
   fan-out.
4. **CloudKit sync** — mirror `ShareWatchStore`, `profileID` partitioning.
5. **Polish** — Fix Match UI, onboarding, edge cases.
