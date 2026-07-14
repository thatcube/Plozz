# Media-Share Onboarding — UX Research + Proposal

**Status:** Research + proposal for review. **No production code in this pass.**
**Scope (expanded charter):** THE ONE UNIFIED "Add a Media Share" experience,
end-to-end, for **all five transports** (SMB, WebDAV, NFS, SFTP, FTP). The
transport branches ship **headless** transports only; this branch owns the
entire add-a-share UX so it never fragments into five bespoke screens. Three
pillars, one coherent flow:

1. **Discovery** — honesty-first, box-vs-service mental model, the incomplete-
   Bonjour problem; one neutral discovery engine + descriptor registry.
2. **Unified credential + trust entry** — a single, transport-parameterized
   credential + trust-approval flow (auth and trust differ per transport),
   replacing today's separate `AddShareView` (SMB) and `AddWebDAVShareView`.
3. **Manual entry** — a first-class, well-signposted path (non-advertised /
   non-standard ports like Brandon's `:8384` can never be auto-found).

**Companion doc:** [`media-share-proposal.md`](media-share-proposal.md) (the
provider/library side — unchanged by this proposal).

> **Reading order:** §0 TL;DR · §3 concrete journeys (now incl. credentials +
> trust) · §4 comparable apps · §4A **the unified credential/trust flow** ·
> §5 recommended model · §6 **the unified transport descriptor registry** (one
> registry drives discovery *and* auth *and* trust).

---

## 0. TL;DR — the recommendation

**There is really ONE screen that matters: the Connect form.** Everything else
just fills it in for you. Discovery is a *convenience that pre-fills the form*,
never a separate world you have to understand. This is the reframing that fixes
the confusion in v1 (where "box list → a second ways-in screen → …" left it
unclear where you actually type things).

The model in one paragraph:

> You open **Add a Media Share**. You see (1) a list of devices we found on your
> network — tap one to **auto-fill the form** — and (2) an **Enter address**
> button that opens the **same form, blank**. Either way you land on **one
> Connect form**: an address field, a **Protocol line that's already answered
> but changeable** (a dropdown), optional username/password, and **Connect**.
> Pick a found device and it's basically pre-filled — just Connect. Know your
> address (or we found nothing)? Type it, we auto-detect the protocol, Connect.
> Never a silent protocol commit; never a dead-end; never a claim we found
> everything.

Why this is the excellent-UX answer to each worry:

1. **"Where do I actually enter info?"** → Always the **one Connect form**.
   Discovered device = form pre-filled. Manual = form blank. There is no second
   place and no separate "ways in" screen.
2. **"What if you don't autodetect my stuff / I want to type it?"** → **Enter
   address** is a first-class button on the very first screen (not a footnote).
   Same form, you type `host` or `host:port`, we auto-detect on Connect; if
   nothing answers, you pick the protocol yourself and retry. Fully worked in
   §3(d)/(f).
3. **"3–4 things detected — are you auto-filling 3–4 forms?"** → **No.** 3–4
   *devices* = 3–4 rows in the list; you pick one → **one** form. 3–4
   *protocols on one device* = **one** form whose **Protocol dropdown** is
   pre-set to the best one, with the others in the dropdown. Never multiple forms.
4. **"Is it a dropdown to change protocols?"** → **Yes, exactly.** Protocol is a
   single, always-visible, pre-answered dropdown on the Connect form. That both
   *names the door* (fixes the silent-SMB commit) and lets power users switch.
5. **"Does the manual path auto-fill?"** → It auto-fills **when you came from a
   discovered device** (host + detected protocol). It's blank when you chose
   **Enter address** cold. Simple, predictable rule.

Under the hood (unchanged from v1, still the right architecture): **one neutral
discovery engine** — generalize the existing `NWBrowser` (`SMBServiceDiscovery`)
into an engine driven by a `TransportDiscoveryDescriptor` registry (each
transport declares its Bonjour service type(s) + standard port(s) + reuses its
existing `TransportClaimant.probe`). NFS/SFTP/FTP light up as **data**, no
bespoke discovery code.

> **What changed from v1:** the "box" is demoted from *"the entrypoint"* to *"a
> shortcut that pre-fills the one form."* The separate per-box "ways in" screen
> is **gone** — those protocols are now just the options in the Connect form's
> Protocol dropdown. This is simpler, and it's why every one of the questions
> above has a one-line answer.

---

## 1. The problem, precisely

Today's flow (`AddShareView` → `AddShareViewModel` → `MediaShareRouteDetector`):

- **Step 1 "Add a Media Share":** a flat list of SMB servers found via Bonjour
  `_smb._tcp` (`SMBServiceDiscovery`), plus a free-text address field that
  auto-detects SMB vs WebDAV by probing (`MediaShareRouteDetector`).
- **Step 2:** the chosen server's shares are enumerated (guest → credentials),
  or the user types a share name.

Brandon's on-device findings — three real flaws:

1. **Discovery is inherently incomplete, but presented as if complete.**
   It's SMB-only and Bonjour-only, so it structurally cannot see:
   - services on non-advertised ports (his real WebDAV: `http://192.168.68.71:8384/`),
   - non-standard ports,
   - anything that isn't SMB.
   Showing "On your network: [MyNAS]" implies *that's what your network has*.
   A user who sees only an SMB row concludes "my NAS only does SMB" — a false
   claim the UI made by omission. **This is a trap, not a bug.**

2. **Selecting a discovered NAS silently commits to SMB.** The row is
   unlabeled; tapping it drops the user into SMB login with no indication a
   protocol was even chosen. The WebDAV (or NFS/FTP) "door" into the *same box*
   is invisible.

3. **No clear mental model.** Is the user connecting to a **box** (their NAS) or
   a **service** (their FTP)? Does listing the NAS help or confuse? If they came
   to add FTP, do they even expect to see their NAS in a list?

### 1.1 Two detection channels, and the (narrow) irreducible limit

The single most important clarification — because "standard port" is a misleading
phrase. There are **two independent detection channels**, and the **port number
only matters to one of them**:

- **Channel A — Bonjour/mDNS (port-independent).** When a service advertises
  itself, the advertisement **includes its port**. So a WebDAV server on `:8384`
  that announced `_webdav._tcp` would be found **at `:8384` automatically** — the
  port is irrelevant here. A service is missed on this channel only when it
  **doesn't advertise at all** (or is on another subnet mDNS can't cross).
- **Channel B — port sweep on an already-known device (curated list).** For a
  box whose IP we already have (found via Bonjour on *any* service, or typed by
  the user), we can probe a **curated list of ports** for other transports. Here
  the port list is **our choice** — and it can include popular **app-default**
  ports, not just protocol well-known ones.

Why this matters for Brandon's `:8384` Unraid WebDAV: `8384` is not a *protocol*
well-known WebDAV port (those are 80/443), but it **is** that app's **default**.
So it becomes auto-detectable through a realistic chain: Unraid almost certainly
advertises **SMB** (`_smb._tcp`) → Channel A finds the **box + its IP** → Channel
B sweeps a curated list that **includes 8384** → the WebDAV door is revealed **with
no typing**. The fix is *data* (put 8384 in the curated list), not a new mechanism.

| Situation | Kind | Consequence |
| --- | --- | --- |
| Service **advertises** via Bonjour (any port) | **Detectable** (Channel A) | Found automatically, port and all. |
| Service **doesn't advertise**, but its box is known (advertises something else, or user typed the IP) **and** its port is in our curated sweep | **Detectable** (Channel B) | Found automatically. **Curating the port list (e.g. add Unraid's 8384) expands this set — a design lever, not a limit.** |
| Service doesn't advertise, box is known, but port is **outside** our curated sweep | **Choice → then irreducible** | Widen the list to catch it; beyond that, user types it once. |
| Box advertises **nothing at all** (we never learn its IP) | **Effectively irreducible on a passive LAN** | User types the address once. (A full-subnet active scan *could* find it, but it's slow and reads as hostile port-scanning — opt-in "deep scan" at most.) |
| Different **subnet/VLAN** (mDNS doesn't cross routers) | **Mostly irreducible** | User types it (or runs an mDNS reflector). |
| Transport whose **descriptor isn't registered** | **Choice** | Register the descriptor. |
| A box's protocol list is **provably present, never provably complete** | **Irreducible** | UI must never assert completeness; always offer "enter an address." |

So the **truly irreducible residual is narrow**: a box that advertises nothing at
all, or a service on a port we deliberately chose not to sweep. Everything else is
a curation choice. The design goal stays: whenever the user *does* have to type an
address, make it feel normal (a first-class peer), not like failure.

**The load-bearing principle: honesty-first.** Discovery may only ever say "here
is what we detected," never "here is everything your network has." Every screen
that shows detected things also shows a way past them (Enter an address).

---

## 2. What already exists (the seams we build on)

The transport-neutral spine is already in place — the proposal extends it, it
does not reinvent it.

- **`Sources/AppShell/MediaShareRouteDetector.swift`** — the `TransportClaimant`
  registry. Each transport declares `decisiveRoute(for:)` (no-network claim from
  explicit scheme / well-known port) and `probe(_:)` (active network check).
  `SMBClaimant` owns `smb://` + port 445; `WebDAVClaimant` owns `http(s)://` +
  probes over HTTP. Detection is phased (decisive → probe → fallback) so **typed
  intent is never lost**. This is the exact neutral pattern discovery should
  share — the probe half of a descriptor.
- **`Sources/ProviderShare/SMBDiscovery.swift`** — `SMBServiceDiscovery`, an
  `NWBrowser` over `_smb._tcp` that streams `DiscoveredSMBServer`s and resolves
  each to host/port. **This is the engine to generalize** — the browsing/resolve
  machinery is transport-agnostic; only the hard-coded `"_smb._tcp"` and the
  SMB-typed result are specific.
- **`Sources/CoreModels/NetworkMediaSources.swift`** — `MediaShareTransportKind`
  (`smb`/`webDAV`/`nfs`/`sftp`), its scheme mapping, and `badgeLabel`. Already
  the single source of truth for "what transports exist."
- **`Sources/CoreUI/ProviderBrandMark.swift`** — the drive glyph with a
  knockout transport badge (SMB/WebDAV/NFS/…). Already renders any transport
  label; the Protocol dropdown and device rows reuse it directly.
- **Post-add reality — `ServerGroupingTests`:** the Settings server list groups
  media-share accounts by `provider | host | transport`. SMB and WebDAV on the
  same host are **deliberately two separate server rows** (a regression was
  filed when they collapsed). So *after* onboarding, the app is **service-
  centric**: the unit is (host, transport), not the box.

> **Key tension to reconcile (see §5.3):** onboarding wants to be *box-centric*
> (honest about one physical NAS and its many doors), but the persisted model is
> *service-centric* (one row per door). The proposal keeps the box as a
> **transient onboarding lens** over service-centric accounts — the box is how
> you *find and reason*, the (host, transport) share is what you *save*.

---

## 3. User journeys — concrete, screen by screen

First, the two screens every journey uses. There are only two.

### Screen 1 — "Add a Media Share"

```
┌ Add a Media Share ─────────────────────────────────────────┐
│                                                            │
│  DETECTED AUTOMATICALLY                    (scanning …)     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 🖴  MyNAS            192.168.68.71 · SMB · WebDAV   › │  │  ← tap = pre-fill
│  │ 🖴  Basement        192.168.68.42 · SMB            › │  │     the form & go
│  └──────────────────────────────────────────────────────┘  │
│  Don’t see yours? Some devices don’t announce themselves — │  ← minimal honesty,
│  enter its address below.                                  │     points to the fix
│                                                            │
│  OR ENTER AN ADDRESS                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ ⌨  Type an address…    e.g. 192.168.68.71:8384     › │  │  ← same form, blank
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

- **Wording decision (per Brandon):** the section is **"Detected automatically"**,
  never "On your network" — because a device *can* be on your network yet not in
  this list (non-advertised, non-standard port, different subnet). The title
  itself carries the honesty, so the sub-line shrinks to a single, action-
  oriented pointer ("Don't see yours? … enter its address below") rather than a
  disclaimer paragraph. Minimal text, honest by construction.
- If nothing is detected, the box shows one calm line ("Nothing detected
  automatically yet. Some devices don't announce themselves (or use an unusual
  port) — enter its address below.") — no error framing.

### Screen 2 — "Connect" (the one and only form; every path lands here)

```
┌ Connect ───────────────────────────────────────────────────┐
│  Address                                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 192.168.68.71                                         │  │  ← pre-filled from a
│  └──────────────────────────────────────────────────────┘  │     device, or blank
│                                                            │
│  Protocol   ┌───────────────┐                              │  ← ALWAYS shown,
│             │ SMB         ▾ │  (WebDAV, NFS…, Other, Auto)  │     pre-answered,
│             └───────────────┘                              │     changeable
│                                                            │
│  Username (optional)   ┌────────────────────┐              │
│  Password (optional)   ┌────────────────────┐              │
│                                                            │
│  [ Connect ]                                                │
│  We check this device for other ways in as you go.         │  ← honesty line
└────────────────────────────────────────────────────────────┘
```

- **Protocol dropdown states:** pre-set to the detected protocol (or the *best*
  when several were found); its menu lists the **other detected protocols
  first**, then the rest, then **"Other / type a port…"** and **"Auto-detect"**.
- **Address blank + Protocol = Auto-detect** is the manual/no-detect default:
  Connect runs the probe and fills the protocol in for you.
- After Connect succeeds, the flow continues into that transport's **existing**
  next step (SMB → pick a share; WebDAV → confirm folder/trust) — unchanged.

Now the journeys. Each is literal button presses.

### (a) One device, one protocol (happy path) — 2 taps, no typing

1. Add a Media Share → **MyNAS** appears under "On your network."
2. Tap **MyNAS** → Connect form opens **pre-filled**: Address `192.168.68.71`,
   Protocol **SMB** (we probed; only SMB answered).
3. Tap **Connect** → SMB share list → pick share → done.

*No typing, protocol is named (not silently committed), and the "other ways in"
honesty line is present in case they expected WebDAV.*

### (b) One device, several protocols — SMB + WebDAV + FTP — still one form

1. Tap **MyNAS**.
2. Connect form pre-filled: Address `192.168.68.71`, **Protocol dropdown pre-set
   to the best door** (say SMB for LAN speed). Opening the dropdown shows
   **SMB · WebDAV · FTP** (the ones we found) then Other/Auto.
3. Leave it on SMB and Connect — or switch the dropdown to **WebDAV** and
   Connect. **One form, one dropdown. Never 3 forms.**

*This is the fix for the invisible-door flaw: all the doors are simply the
dropdown's options, right where you'd change your mind.*

### (c) Multiple devices, several protocols each — pick one row, one form

1. "On your network" lists **MyNAS**, **Basement**, **Office** (3 rows — one per
   device, no matter how many protocols each has).
2. Tap the one you want → **one** Connect form, pre-filled, its Protocol dropdown
   holding that device's found doors.

*3–4 detected devices = 3–4 rows and you pick one. We never open or pre-fill
several forms at once.*

### (d) Non-standard / non-advertised port — Brandon's `192.168.68.71:8384` — first-class

Two equally-supported ways in:

- **If the device also shows up for something else** (e.g. it advertised SMB):
  tap it → Connect form pre-filled with the host → change **Address** to
  `192.168.68.71:8384` (or open Protocol → **Other / type a port…**) → Connect →
  we detect WebDAV on `:8384`. The host is already filled, so it's a tiny edit.
- **If the device advertises nothing at all:** tap **Enter address** → type
  `192.168.68.71:8384` → Protocol left on **Auto-detect** → Connect → WebDAV
  detected. Done.

*Either way it's the normal Connect form, not a consolation prize. The
irreducible cost is typing the address once — with zero protocol knowledge
required, because Auto-detect handles the scheme.*

### (e) Media SERVER (Jellyfin/Plex/Emby) vs. a file SHARE — stay separate

Unchanged intent from v1: this flow is for **file shares only**. Adding a
Jellyfin/Plex **server** is its own existing flow (`ProviderKind.jellyfin/plex`
vs `.mediaShare`), because a "library app" and a "folder of files" are different
mental models and must not be blended into one list. **Stretch (optional):** if,
while probing a device, we also see a Jellyfin/Plex handshake on a standard port,
show a one-line hint on the Connect form — "This device also runs a Jellyfin
server — add it as a server instead?" — as a shortcut, not a merge. Gated behind
a media-server descriptor; not core.

### (f) The "we found nothing / I just want to type it" path — explicitly excellent

This is the path Brandon flagged as under-served. It is a **peer**, not a
fallback:

1. Add a Media Share. Whether or not anything was discovered, **Enter address**
   is right there.
2. Tap it → blank Connect form, Address focused, Protocol on **Auto-detect**.
3. Type `mynas.local` or `192.168.68.71:8384` → **Connect**.
4. We probe: found → proceed into that transport's flow; **found nothing** →
   the form stays, with a clear line ("Couldn't reach a share there — check the
   address, or choose a protocol and try again") and the Protocol dropdown lets
   them **force** SMB/WebDAV/NFS/… and retry. No dead-end.

*The person who wants full manual control never has to touch discovery, never
sees it as the "real" way, and is never blocked by a failed auto-detect.*

### (g) SFTP — password or key, and a required host-key approval

- **Mental model:** "It's my SSH box; I trust it, but the app should prove it's
  the same box next time." SFTP is the transport with the strictest trust rule.
- **Flow:** Locate (device or address) → **Authenticate** card shows **Password ·
  Generated key** (the descriptor's set; no anonymous/bearer). → On first connect
  the generic **"Verify Host Key"** screen shows the SSH host-key SHA-256 →
  **Approve & Continue** pins it (required — the vault refuses an unpinned SFTP
  credential). → browse folders → name → save.
- *Same screens as WebDAV, different labels/fields — because the descriptor says
  "auth = {password, generatedKey}, trust = sshHostKey(required)".*

### (h) NFS — no credentials at all

- **Mental model:** "It's an export; there's no login." NFS auth is host-based,
  not user-based.
- **Flow:** Locate → **the Authenticate step is skipped entirely** (descriptor
  says `noCredentials`; no credential card, no trust screen) → browse folders →
  name → save. The shortest possible path — and the UI shows *nothing* it doesn't
  need, because it's all descriptor-driven.

### (i) FTP — anonymous/password with an honest plaintext warning

- **Mental model:** "Old-school FTP on my NAS." The risk is invisible: FTP sends
  the password in the clear.
- **Flow:** Locate → **Authenticate** shows **Anonymous · Username/Password**
  with a **persistent warning** ("FTP sends your username and password
  unencrypted…") whenever a non-anonymous mode is selected — the same treatment
  `http://`-with-credentials already gets for WebDAV → no trust step → browse →
  save. Honesty-first extends to security, not just discovery.

### Journey synthesis

| Scenario | Taps / typing | Where you enter info | Protocol handling |
| --- | --- | --- | --- |
| (a) 1 device/1 proto | 2 taps, no typing | Connect form (pre-filled) | named, 1 option |
| (b) 1 device/N proto | 2–3 taps, no typing | Connect form (pre-filled) | dropdown, pre-set |
| (c) N devices/N proto | pick row → Connect | Connect form (pre-filled) | dropdown, pre-set |
| (d) non-std port | tiny edit or short type | Connect form | Auto-detect / Other-port |
| (e) server vs share | separate flow | (server flow) | n/a + optional hint |
| (f) manual / no-detect | type address | Connect form (blank) | Auto-detect, or force |
| (g) SFTP | pick/type + host-key OK | Connect form | password/key + **host-key pin** |
| (h) NFS | pick/type, no login | Connect form (no creds) | n/a (`noCredentials`) |
| (i) FTP | pick/type + warning | Connect form | anon/password + **plaintext warning** |

### 3.1 Direct answers to the open UX questions

- **"add share → select box → manually enter info how?"** You usually **don't
  need to** — selecting a device pre-fills the Connect form (address +
  protocol); you just add a password if asked and press Connect. If you *want*
  to change something, you edit the pre-filled Address or the Protocol dropdown
  right there.
- **"or do I enter my info on step 2 instead?"** Manual is a peer choice on
  **step 1** ("Enter address"), which opens the **same** Connect form blank.
- **"what if we don't autodetect their stuff?"** Use **Enter address**, type it,
  Auto-detect runs on Connect; if it finds nothing you force the protocol from
  the dropdown and retry. Journey (f).
- **"does step 3 auto-fill?"** There is no separate step 3 — there's one Connect
  form. It **auto-fills when you came from a discovered device**; it's **blank**
  when you chose Enter address.
- **"3 or 4 detected — auto-filling 3–4 forms?"** No. Devices → rows (pick one).
  Protocols on one device → one form, one **dropdown**.
- **"is it a dropdown to change protocols?"** Yes — a single always-visible
  dropdown, pre-answered, with the found doors on top.

---

## 4. How comparable apps solve it (research)

> Sourced via web research on public docs/behavior of each app. Treat as
> directional patterns rather than exact citations; the design conclusions
> (§5–§6) stand on the journey analysis, with these as corroboration.

- **Infuse (Apple TV)** — *box-centric discovery.* Auto-scans and lists devices
  **by device name** ("NAS-Server", "MyPC"), often with their shares beneath;
  select a device → browse its shares. A separate **manual "Add Server"**
  (address + share + credentials) is positioned as precise/reliable and is the
  documented answer **when discovery fails** (different subnet/VLAN, firewall
  blocks mDNS/NetBIOS, discovery disabled). Confirms two things we want: the box
  as the unit, and manual-add treated as a legitimate co-path — not a footnote.
- **VLC (tvOS)** — *discovered vs. saved, protocol in the URL.* A "Local Network"
  section lists discovered SMB/UPnP/FTP; a separate **"Add Server"** takes a URL
  **with the scheme** (`smb://…`, `ftp://…`). Discovered and manually-saved
  servers are visually distinct sections. Validates a persistent, visible manual
  entry — but pushes protocol knowledge onto the user (type the scheme), which
  Plozz's auto-detecting detector already improves on.
- **Kodi** — *protocol-first (the anti-pattern for us).* "Add source → Browse"
  makes you **pick the protocol first** (SMB / NFS / WebDAV / FTP / SFTP), then
  browse or "Add network location…" to type server + credentials. Maximum
  flexibility, maximum cognitive load: the user must know their protocol up
  front. This is exactly the *service-first* mental model we're trying to avoid
  for the common case — instructive as what **not** to lead with.
- **macOS Finder** — *two coexisting models.* Bonjour sidebar browsing shows
  boxes (and, tellingly, **lists a box more than once when it advertises multiple
  protocols** — the service model leaking into the box view), preferring SMB on
  open; **Connect to Server (⌘K)** is explicit-scheme, precise, discovery-
  independent. Confirms the tension we already have in `ServerGroupingTests`
  (one box, many services) and that a precise manual path must always exist
  alongside browsing. Our improvement over Finder: don't list the box N times —
  list it **once** and reveal its doors *inside* it.
- **Jellyfin / Plex native clients** — *server, not share, discovery.* They
  discover their **own** servers (Plex GDM, Jellyfin mDNS/`/system/info`
  handshake), not file shares, and always offer manual server URL entry. Relevant
  as the **server-vs-share** boundary (scenario e): keep file-share discovery
  distinct from media-server discovery.

**Cross-app takeaways that shape the design:**
1. The best consumer flows (Infuse) are **box-centric** with a **first-class
   manual path**; the power flows (Kodi) are protocol-first and heavier.
2. **Everyone** treats discovery as incomplete and keeps manual entry
   permanent — validating honesty-first.
3. Finder's "box appears once per protocol" is a **known confusion** we can beat
   by collapsing to one device + a single Protocol dropdown.

---

## 4A. The unified credential & trust flow (the new charter half)

This is the part that must **not** become five screens. The insight: the app
**already has a transport-neutral credential model**, and the transport→auth→trust
rules are **already codified**. The UI just has to render that model generically.

### 4A.1 What already exists (don't rebuild it)

- **`MediaShareCredentialEnvelope { transport, authentication, trust }`**
  (`FeatureAuth/MediaCredentialVault.swift`) is the single persisted shape for
  every transport.
- **`MediaShareAuthentication`** already has every case we need: `anonymous`,
  `password(user,pass)`, `bearer(token)`, `generatedKey(username, keyID)`,
  `noCredentials`.
- **`MediaShareTrustMaterial`** already carries **both** pin kinds:
  `tlsLeafCertificateSHA256` (WebDAV) **and** `sshHostKeySHA256` (SFTP), plus a
  `revision` UUID — this *is* the "trust-revision plumbing" the transport
  branches are wiring their host-key/TLS pins through.
- **The compatibility matrix is enforced in `validate()`** — so it's not a UI
  invention, it's the system's law:

| Transport | Auth modes allowed | Trust pin | Plaintext-credential risk |
| --- | --- | --- | --- |
| **SMB** | anonymous, password | — | — |
| **WebDAV** | anonymous, password, bearer | TLS leaf (optional, TOFU) | yes on `http://` |
| **SFTP** | password, generated key | SSH host key (**required**, TOFU) | — (SSH encrypts) |
| **NFS** | *none* (`noCredentials`) | — | — |
| **FTP** *(planned; not yet in the enum)* | anonymous, password | — | **yes** (FTP is plaintext) |

- **`AddWebDAVShareViewModel` is the state-machine template**: an immutable
  `Attempt` snapshot (so editing mid-flight can't send new creds to the old
  origin), a `generation` counter (so a superseded async response is ignored), a
  TOFU `confirmTrust(sha256)` step, and a browse step. **Everything the unified
  flow needs is already proven here** — it just needs to be driven by transport
  metadata instead of being WebDAV-specific.

### 4A.2 The unified flow — one state machine, parameterized by the transport

After **Locate** (§3 discovery/manual) resolves a transport + address, the same
four generic steps run for **every** transport; each step *reads the descriptor*
(§6) and renders only what applies:

```
 LOCATE ─▶ AUTHENTICATE ─▶ [APPROVE TRUST] ─▶ PICK LOCATION ─▶ NAME & SAVE
 (device/   (fields chosen   (only if the       (list children:  (display name →
  address    by the transport's descriptor        SMB shares /     persist the
  → route)   auth-mode set)   requires a pin)      folders)         envelope)
```

1. **Authenticate — one form, fields chosen by metadata.** The credential card
   shows an auth-mode control populated **from the descriptor's allowed set**:
   - SMB → Anonymous · Username/Password
   - WebDAV → Anonymous · Username/Password · Bearer token
   - SFTP → Password · Generated key
   - NFS → *(no credential card at all — `noCredentials`)*
   - FTP → Anonymous · Username/Password, **with a persistent "FTP sends your
     password unencrypted" warning** (reuses the exact pattern of today's
     `insecureHTTPWarning`).
   The `http://`-with-credentials plaintext warning already exists for WebDAV and
   generalizes to a descriptor-declared `plaintextCredentialWarning`.

2. **Approve trust — ONE generic fingerprint screen, two pin kinds.** The
   existing "Verify Certificate → show SHA-256 → Approve & Continue / Cancel →
   pin the leaf" screen becomes a neutral **"Verify this server"** screen driven
   by the descriptor's trust kind:
   - WebDAV/HTTPS self-signed → **"Verify Certificate"** (TLS leaf SHA-256).
   - SFTP → **"Verify Host Key"** (SSH host-key SHA-256) — **required** on first
     connect (matches the vault's "SFTP must have a host-key pin" rule).
   - SMB/NFS/FTP → step **skipped** (no pin kind).
   Same TOFU shape, same "approving pins this exact key; a change requires
   re-approval" copy, same reject-supersedes-in-flight behavior. Only the title,
   the fingerprint label, and which `MediaShareTrustMaterial` field is filled
   differ — all from the descriptor.

3. **Pick location — the same "list children" step, two renderers.** SMB
   enumerates **shares**; WebDAV/FTP/SFTP/NFS browse **folders**. Both are "list
   the children at this path and let the user drill/confirm" — the existing SMB
   share-picker and WebDAV PROPFIND browser are two implementations of one
   `listChildren(path)` the transport already provides. The UI is one browser
   view; the transport supplies the listing.

4. **Name & save.** Display name → construct and persist the
   `MediaShareCredentialEnvelope` (+ any approved pin) exactly as the two flows
   do today. Persistence and the service-centric Settings grouping are unchanged.

### 4A.3 Why this is one flow, not five

Every per-transport difference is **data on the descriptor**, consumed by generic
UI: *which auth modes*, *whether a trust step runs and what it's called*, *what
warning to show*, *how children are listed*. Adding FTP = adding its descriptor +
the enum case + a `noCredentials`-style vault rule; **zero** new onboarding
screens. This is the same "add a case, not a screen" discipline the
`MediaShareRouteDetector` and the vault already follow — extended to the whole
add-a-share UX.

### 4A.4 Security invariants carried over (must not regress)

- **Credentials are Keychain-only**, never `UserDefaults`/logs (repo invariant);
  the vault already enforces this — the unified UI must keep routing through it.
- **Trust-before-credentials ordering:** for HTTPS, trust is preflighted and
  approved **before** any credential is sent (today's WebDAV behavior). The
  generic flow preserves this: Authenticate collects input, but the network
  attempt does trust → then credential validation, per the `Attempt` snapshot +
  `generation` guard.
- **No credential smuggling via URL** (userinfo/query/fragment rejected) — the
  existing parse guards move into the shared address parser.

---

## 5. The recommended onboarding model

### 5.1 Shape — two screens, one form

The full wireframes are in **§3** (Screen 1 "Add a Media Share" and Screen 2
"Connect"). The essence:

- **Screen 1** = a list of discovered **devices** (tap = pre-fill & go) + an
  **Enter address** button (same form, blank). Not a separate "box tier" to
  understand — just shortcuts into the form.
- **Screen 2 "Connect"** = the single form every path lands on: **Address** +
  an always-visible, pre-answered **Protocol dropdown** + optional
  username/password + **Connect**. Multiple protocols on a device are the
  *dropdown's options*, not a separate screen and not multiple forms.

The v1 "WAYS IN" screen is **deleted**; its content is the Protocol dropdown.
This is the single biggest simplification and the answer to "where do I enter
info / is it a dropdown?"

### 5.2 Rules that make it honest, simple, and scalable

- **One device, listed once** (beats Finder's N-per-protocol listing). Each row
  **names the detected protocol(s)** — "MyNAS · SMB · WebDAV", not a vague "2
  ways in" count — since Bonjour already tells us which service advertised (a
  probe-on-select may still reveal more, per the honesty line).
- **The Connect form is the only place data is entered** — pre-filled from a
  device, blank from Enter address. No second data-entry surface.
- **Protocol is always shown and pre-answered, never silently committed.** It's
  a disclosure ("Protocol: SMB ▾"), not a decision the user must make — but it's
  *right there* to change, which names the door and exposes the others.
- **Manual (Enter address) is a first-class peer on Screen 1**, not a footnote,
  and works identically whether or not discovery found anything.
- **Auto-detect is the manual default** so typing an address needs zero protocol
  knowledge; the dropdown lets a user *force* a protocol if detection fails.
- **Two honesty lines**, always: Screen 1 ("not every device") and Screen 2
  ("we check for other ways in as you go") — the app never claims completeness.

### 5.3 Optional nicety — single-tap add for the pure happy path

For a discovered device where exactly one protocol answered and it needs no
credentials (guest), the pre-filled Connect form is *already complete*. Two
choices (an **open question**, §8): either (a) still show the form so the first
add teaches the model, or (b) skip straight to the share picker and show the
form only when there's a choice to make. Recommendation: **show the form the
first time, remember the preference** — teaches once, fast forever.

### 5.4 Reconciling with the service-centric persisted model

Unchanged from the analysis: a discovered "device" is an **onboarding
convenience only**. Adding the SMB door persists a `(host, transport=smb)`
account; later adding WebDAV persists a second `(host, transport=webdav)`
account — matching the shipped `ServerGroupingTests` (two rows, one per door).
Onboarding does **not** touch persistence or the Settings server list.

### 5.5 Why this beats the alternatives

- **vs. v1's box→ways-in→form:** fewer surfaces, one obvious data-entry place,
  and every "where/how do I…" question has a one-line answer (§3.1). Same
  discovery benefit, far less to understand.
- **vs. Kodi's protocol-first:** the common user never has to know their
  protocol up front (Auto-detect), but the power user still can (dropdown).
- **vs. manual-only:** keeps the genuine no-typing convenience of Bonjour on
  tvOS (where typing an IP with a remote is painful) for scenarios (a)–(c).
- **vs. today:** kills the silent-SMB commit (protocol is named), the invisible
  WebDAV door (it's a dropdown option), and the "manual feels like a fallback"
  framing (Enter address is a peer).

---

## 6. Architecture proposal — ONE descriptor registry drives discovery, auth & trust

**Hard constraint honored:** no per-transport bespoke discovery *and* no
per-transport bespoke onboarding. A single neutral registry of **transport
onboarding descriptors** feeds three generic consumers — the discovery engine,
the credential form, and the trust screen. SMB/WebDAV/NFS/SFTP/FTP are **data**,
not code paths.

### 6.1 The unified transport onboarding descriptor

Each transport declares itself **once**; every generic surface reads from it.
This subsumes the discovery-only descriptor from v1 and adds the auth/trust
metadata that §4A needs (all of which already exists as vault rules — the
descriptor just surfaces it to the UI):

```swift
struct TransportOnboardingDescriptor: Sendable {
    let kind: MediaShareTransportKind            // smb / webDAV / nfs / sftp / (ftp)

    // --- discovery ---
    let bonjourServiceTypes: [String]            // ["_smb._tcp"], ["_webdav._tcp","_webdavs._tcp"], ["_nfs._tcp"], ["_sftp-ssh._tcp"], ["_ftp._tcp"]
    // Curated ports to probe on an ALREADY-KNOWN device (Channel B, §1.1).
    // Includes protocol well-known ports AND popular app defaults, so a box
    // that doesn't advertise WebDAV can still be found — e.g. Unraid's :8384.
    let sweepPorts: [Int]                         // [445] ; [80,443,8384,8080,8443] ; [2049] ; [22] ; [21]
    // Reuse the EXISTING probe half of the transport's TransportClaimant so
    // "is transport T at host:port?" has ONE implementation shared by the
    // route-detector AND discovery.
    let probe: @Sendable (_ host: String, _ port: Int?) async -> Bool

    // --- authenticate (mirrors the vault's validate() matrix) ---
    let authModes: [MediaShareAuthMode]          // e.g. [.anonymous,.password] ; [.anonymous,.password,.bearer] ; [.password,.generatedKey] ; [.none]
    let plaintextCredentialWarning: PlaintextRisk // .never ; .whenInsecureScheme (http) ; .always (ftp)

    // --- approve trust (which MediaShareTrustMaterial slot, and is it required) ---
    let trust: TrustRequirement                   // .none ; .tlsLeaf(optional) ; .sshHostKey(required)

    // --- pick location (the "list children" renderer) ---
    // Provided by the transport resolver; SMB = shares, others = folders.
    // The UI is ONE browser; the transport supplies listChildren(path).
}
```

The `authModes`, `plaintextCredentialWarning`, and `trust` fields are **not new
policy** — they restate what `MediaCredentialVault.validate()` already enforces,
so the descriptor and the vault can be cross-checked (a test asserts every
descriptor's declared auth set exactly matches what the vault accepts for that
transport, preventing drift).

**One registry, one composition root.** The `[TransportOnboardingDescriptor]` is
built at the same place that composes the `MediaShareRouteDetector` claimant list
— so detection, discovery, auth, and trust all stay in lockstep and a new
transport is registered **exactly once**.

### 6.2 Generalize the browser (not rewrite it)

`SMBServiceDiscovery`'s `NWBrowser`/`ResolveBox` machinery is already transport-
agnostic except for the literal `"_smb._tcp"` and the SMB-typed result.
Refactor into a `BonjourServiceDiscovery` that:

- browses **all** `bonjourServiceTypes` across **all** descriptors,
- resolves each result to `(host, port)` exactly as today,
- tags each result with the **descriptor kind** that owns the service type,
- yields a neutral `DiscoveredService { kind, name, host, port }`.

`SMBServiceDiscovery` becomes a thin wrapper (or is retired) — its resolve/de-dup
logic moves wholesale into the neutral engine, so this is a **generalization,
not a reinvention** (satisfies the "generalize the NWBrowser engine" directive).

### 6.2A The unified onboarding state machine (generalize the WebDAV VM)

`AddWebDAVShareViewModel` already implements the exact machine §4A needs —
immutable `Attempt` snapshot, `generation` guard, TOFU `confirmTrust`, browse.
Lift it into a transport-neutral `AddMediaShareFlowModel` whose steps read the
descriptor: `authenticate` (fields from `authModes`) → `approveTrust` (shown iff
`trust != .none`, labeled by kind) → `pickLocation` (transport's `listChildren`)
→ `save` (build the `MediaShareCredentialEnvelope`). `AddShareView` (SMB) and
`AddWebDAVShareView` collapse into this one flow; the SMB share-enumeration and
WebDAV PROPFIND become two `listChildren` implementations.

### 6.3 Grouping + the curated port sweep (Channel B)

- **Group discovered services by box** = host identity (collapse IPv4/IPv6/`.local`
  records for one host, as `ResolveBox` already de-dups today), producing
  `DiscoveredBox { host, displayName, foundServices: [kind] }`.
- **On box select (or manual address):** run each descriptor's `probe` against
  its `sweepPorts` **in parallel** → the doors we can reach. This is the same
  probe the route-detector uses, so behavior is consistent and there's one place
  to fix a transport's detection.
- **This is Channel B (§1.1):** it lets a box that *didn't* Bonjour-advertise a
  transport still reveal it when it sits on a **curated** port — and because the
  list can include **app defaults** (e.g. Unraid WebDAV `:8384`), it closes most
  of the flaw-#1 gap for real setups. Bounded to the curated list, so it stays
  cheap; never claimed complete (Enter-an-address remains the honest backstop).

### 6.4 What each transport contributes (illustrative, not implemented here)

| Transport | Bonjour service type(s) | Curated sweep ports | Probe (reuse) |
| --- | --- | --- | --- |
| SMB | `_smb._tcp` | 445 (139 legacy) | TCP-connect (as discovery resolve does today) |
| WebDAV | `_webdav._tcp`, `_webdavs._tcp` | 80, 443, **5005, 5006** (Synology/QNAP WebDAV), 8080, 8443, 8000, 8888, **8384** | existing `WebDAVReachabilityProbe` OPTIONS |
| NFS | `_nfs._tcp` | 2049 (111 portmapper) | TCP-connect |
| SFTP | `_sftp-ssh._tcp` | 22 | TCP-connect / SSH banner |
| FTP | `_ftp._tcp` | 21 (990 FTPS) | TCP-connect / FTP banner |

*Sweep-port research (Synology/QNAP/Unraid/TrueNAS/Nextcloud):* the WebDAV list
is the interesting one — **5005/5006 are the Synology & QNAP WebDAV defaults**,
NAS admin UIs that often reverse-proxy WebDAV live at Synology **5000/5001** and
QNAP **8080**, and app containers (like Brandon's Unraid **8384**) use arbitrary
high ports. A ~30-port curated union covers essentially every real consumer NAS.

Each transport is **one descriptor** (Bonjour type(s), sweep ports, probe,
`authModes`, `trust`) plus its existing `TransportClaimant` for typed-address
detection. **Discovery, the credential card, and the trust screen all light up
for free** once the descriptor exists — no new onboarding code per transport.

### 6.4A Why a curated sweep, not a full 65k-port scan (Apple TV cost)

A full 1–65535 scan on the Apple TV is technically possible but a poor default:

- **Time is unbounded in the common case.** If the host **RSTs** closed ports (no
  host firewall — typical LAN NAS), each probe resolves in ~1–10 ms and a full
  sweep at ~200 concurrent connections is seconds. But if the host **silently
  drops** closed ports (firewalled), each probe hangs to the timeout (~1–2 s):
  65 535 ÷ 200 × 1.5 s ≈ **6+ minutes** — and we can't know which regime a host
  is in before scanning.
- **Device cost is manageable but not free.** Hundreds of concurrent
  `NWConnection`s = tens of MB + connection-churn CPU (fine on a plugged-in ATV);
  thousands hit file-descriptor limits and Network.framework throttling.
- **It looks hostile.** 65k SYNs to one host is textbook port-scanning; NAS
  security tooling (fail2ban, Synology Security Advisor) may **ban the Apple TV's
  IP.**

**Decision:** a **curated ~30-port list** (§6.4) is near-instant (<~1 s),
non-hostile, and catches virtually every real NAS. Offer a **bounded, opt-in
"deep scan"** (explicit consent + progress + cancel, rate-limited) for the rare
holdout — never the default. Both are just data/policy on the descriptor + a
flag, so tuning later is trivial.

### 6.5 The narrow irreducible residual — made normal

Per §1.1, most "non-standard port" cases are actually **detectable** via Channel
A (advertised → port-independent) or Channel B (curated sweep on a known box). The
residual that genuinely needs typing is narrow: a box that advertises **nothing**
(so we never learn its IP), or a service on a port we deliberately didn't sweep.
For those, the design makes typing first-class (top-level **Enter an address** +
per-box "connect another way", pre-seeded host, auto-detecting scheme), so the
cost is one field entry with zero protocol knowledge — never a dead-end.

---

## 7. Proposed implementation phases (for the eventual, approved build)

No code this session. When approved, suggested order (each phase is
behavior-preserving + unit-testable via injected probes, as the WebDAV VM and
detector already are):

1. **Unified descriptor + neutral discovery engine.** Introduce
   `TransportOnboardingDescriptor` + registry (§6.1); extract
   `BonjourServiceDiscovery` from `SMBServiceDiscovery` (§6.2); wire SMB + WebDAV
   descriptors reusing existing probes. Add a test asserting each descriptor's
   `authModes`/`trust` matches `MediaCredentialVault.validate()` (drift guard).
2. **Unified onboarding state machine.** Lift `AddWebDAVShareViewModel` into a
   transport-neutral `AddMediaShareFlowModel` (§6.2A): `authenticate` →
   `approveTrust` (generic fingerprint screen) → `pickLocation`
   (`listChildren`) → `save`. Fold the SMB flow in as a `listChildren`
   implementation. **This is the "one flow, not five" core.**
3. **Onboarding UI rework.** The Screen-1 device list + **Enter address**, the
   single **Connect form** (Protocol dropdown, Auto-detect default, honesty
   lines), the generic credential card (fields from `authModes`, plaintext
   warning), the generic **Verify** trust screen (TLS leaf / SSH host key), the
   one browser view. Replace `AddShareView` + `AddWebDAVShareView`.
4. **Device grouping + standard-port probe** to populate the Protocol dropdown
   and pre-select the best door.
5. **NFS / SFTP / FTP descriptors** as those headless transports land — each is
   descriptor data (Bonjour type, ports, probe, authModes, trust); **no new
   onboarding screens**. FTP also needs its `MediaShareTransportKind` case + a
   `validate()` rule.
6. **Stretch:** media-server hint on a probed device (scenario e), gated behind a
   media-server descriptor.

Testing follows `docs/testing-policy.md`; injected probes make the discovery
engine, credential form, and trust machine unit-testable without a live network.

---

## 8. Open questions for Brandon

1. **Single-tap happy path (§5.3):** for a discovered device with exactly one
   guest/no-credential protocol, skip the Connect form straight to the location
   picker, or always show the form the first time (teach once) then remember?
2. **Curated sweep-port list (Channel B, §1.1):** how aggressive? Protocol
   well-known only (445 / 80+443 / 2049 / 22 / 21), or also **popular app
   defaults** like Unraid WebDAV `:8384`, common alt-HTTP `:8080/:8443`, etc.?
   Wider list = auto-detects more boxes like Brandon's with zero typing, at the
   cost of more speculative connects per device. (This is pure data — easy to
   tune later.) And: offer an opt-in **"deep scan"** that sweeps the whole subnet
   for boxes that advertise nothing, or never?
3. **SFTP "Generated key" onboarding:** the vault supports `generatedKey`
   (app-generated keypair, keyID in the child-item store). Include key auth in
   the first unified UI, or ship password-only for SFTP first and add key auth
   next? (Key auth needs a "copy this public key to your server" step.)
4. **SFTP host-key change / TLS cert change:** re-approval on change is the vault
   model. Is a future "the key changed — approve again?" screen in scope for this
   proposal, or handled at connect-time later?
5. **Media-server hint (scenario e):** worth the stretch, or keep file-share and
   media-server onboarding strictly separate for now?
6. **FTP:** confirmed on the roadmap (needs a new `MediaShareTransportKind` case
   + vault rule), or SMB+WebDAV+NFS+SFTP only for now?
7. **Naming:** "Enter address" / "Protocol" / "Auto-detect" / "Verify Certificate"
   / "Verify Host Key" — keep, or prefer other wording?
8. **Mockup depth:** the current clickable mockup covers discovery + connect +
   location pick. Want me to extend it to show the **credential cards + the trust
   approval screen** per transport (SMB/WebDAV/SFTP/NFS/FTP) so you can see the
   unified auth/trust flow too?

