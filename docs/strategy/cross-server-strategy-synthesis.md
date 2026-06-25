# Plozz Strategy Synthesis — Cross-Server Direction

> **Status: research / proposal only. No production code changed. Nothing here is
> implemented.** This is a decision document for Brandon to react to.
>
> Synthesized from **5 independent strategy-research branches** that were each
> given the same brief in parallel, with different models and no knowledge of each
> other's answers:
>
> | # | Model | Branch | One-line thesis |
> |---|---|---|---|
> | R1 | Opus 4.8 (high) | `thatcube-strategy-research-opus48` | Plozz is a **cross-server truth layer** — own the seam |
> | R2 | GPT-5.3-Codex (xhigh) | `thatcube-strategy-r2-codex-5-3-xhigh` | **Unified by default, explicit by choice, fast always** |
> | R3 | Gemini 3.1 Pro (high) | `thatcube-didactic-dollop` | **Smart client, dumb pipes** — servers are redundant CDNs |
> | R4 | Opus 4.7 (xhigh) | `thatcube-strategy-r4-opus-xhigh` | Plozz is a **Title OS** — servers are delivery routes |
> | R5 | Opus 4.8 (max) | `thatcube-strategy-research-r5` | **Cross-server control plane** — "many servers, one library that never loses your place and never stalls" |
>
> Competitors (Infuse, Swiftfin, Emby, Kodi, JellyPlex, Trakt) were treated as
> **inspiration only** — the explicit instruction was *not* to copy Infuse.

---

## TL;DR — what all 5 independently agreed on

Five models, five framings, **near-total consensus** on the substance:

1. **Library: unified-only is correct. Commit harder.** Every branch rejected
   per-server library tabs/rows and rejected Infuse's "Direct Mode vs Library Mode"
   toggle as a *false choice* forced by a local-cache constraint Plozz doesn't have.
   The server should be a **card attribute / quality chip + the source picker**, never
   a browsing axis or a layout. (R1–R5 unanimous.)

2. **Watch-state is the real problem, and it's the wedge.** All five independently
   found the same core defect: **playback progress is written to only the one server
   you launched from** (`PlayerViewModel.report()` → a single provider), while the
   merged card *displays* a client-side most-recent-wins fold. The unified state is a
   **display illusion**, not real convergence. The fix everyone converged on: make
   Plozz the **canonical watch ledger** and treat servers as replicas it
   reconciles via **write-through fan-out + a durable retry queue (outbox)**.

3. **Differentiate on cross-server *intelligence*, not polish.** The two
   copy-resistant flagships every branch named: **(a) source racing / best-source
   auto-pick** (start from whichever server direct-plays fastest) and **(b) seamless
   mid-stream cross-server failover** (a server dies → keep playing from another
   server's copy at the same position). Both are *structurally impossible* for any
   single-server client.

The disagreements are only about **how much user control to expose** (see §4).

---

## 1. Library architecture — Combine vs Separate

**Verdict: Unified-only by default. Decisively.** No "Plex row", no "Jellyfin row",
no global mode toggle.

### Why (the shared argument)
- The target user (a self-hoster, or a guest on someone's server) thinks *"I have
  Dune,"* not *"I have a Plex copy and a Jellyfin copy of Dune."* Per-server rows
  (Swiftfin's model) externalize an implementation detail and multiply the browsing
  surface.
- Plozz **already** does the thing Infuse makes you choose between — **live AND
  combined at once** (bounded concurrent paging, no big local scan, offline servers
  silently dropped). That is the architectural wedge; don't trade it away for an
  offline cache most TV users never need.

### The one real liability: merge correctness — and the fix everyone reached
Combine's only true downside is wrong merges, and it cuts two ways:
- **Missed merge (bigger real-world problem today):** *series with no external ID
  never merge* (`MediaItemIdentity` carves them out to avoid bridging
  reboots/remakes). On a poorly-tagged Jellyfin library this produces **duplicate
  series cards with split watch-state** — the exact thing Plozz promises to kill.
- **False merge:** movies merged by title+year with bad metadata.

**Consensus fix — graded, user-correctable identity** (don't relax the safe
auto-rules):
- **High confidence** (shared imdb/tmdb/tvdb) → hard-merge silently, as today.
- **Low confidence** (title+year only, or a guarded series title+year+runtime/episode-count
  signal) → **soft link**: shown merged but one tap can split.
- **One-tap "these are / aren't the same"** correction, persisted in a small **local
  identity-override store** fed back into `MediaItemIdentity`. This simultaneously
  *closes the series-missed-merge gap* (user can merge two stubborn duplicates) and
  fixes any rare false-merge — **without** loosening the conservative algorithm.
  R1/R4/R5 all called this a genuine moat ("user-taught identity graph") no
  single-server client can build.

### Secondary, cheap wins flagged
- **Persisted cross-server identity cache** keyed by external ID → merged graph + art
  are instant on cold launch (feeds the speed wedge). *(R1, R5)*
- **Locale-aware title normalization** — current `folding(.diacriticInsensitive,
  .caseInsensitive)` without a locale silently mismatches German ß, Turkish dotless-ı.
  *(R4)*
- **Pick the best poster across sources**, not just the primary's. *(R4)*

### The one split: how much to expose the "source" dimension
- **R2 (Codex)** wants a first-class **"Source Lens"** (All Sources / This Server) +
  visible **merge-confidence tiers** + a **"Why merged?"** sheet — *unified by default,
  but auditable and steerable*, because invisible automation erodes trust.
- **R4 (Opus 4.7)** is the hardliner: **never** ship a user-facing "merge on/off";
  any "Show duplicates" toggle belongs buried in Diagnostics for QA only — *"the moment
  Plozz becomes a configurable tool instead of an opinionated product."*
- **R1/R3/R5** land in between: unified default, server as a **filter facet / quality
  chip**, with provenance always one glance away (an "on N servers" badge + the
  existing detail picker), and a **per-library "keep separate" escape hatch only at
  the margin.**

**My read for you:** ship unified-only + the "on N servers" badge + graded
user-correctable identity now. Treat R2's Source Lens / "Why merged?" as a
*trust-building* follow-on (cheap, optional), and heed R4's warning: do **not** add a
top-level "merge libraries: on/off" switch.

---

## 2. Cross-server watch-state & "play counting"

This is where the research is most valuable. **Your instinct was right, and it's a
real bug — not just a missing feature.**

### Confirmed current behavior (all 5 verified in code)
| Action | Today |
|---|---|
| **Actually watching** (resume %, progress) | Reported to **only the one server you launched from** (`PlayerViewModel.report()`). Jellyfin gets nothing if you watched on Plex. |
| **Manual "Mark watched/unwatched"** | **Already fans out to every server** holding the title (`MediaItemActionCoordinator.watchTargets`) — but writes only the `isPlayed` flag, never a resume position. |
| **Trakt** | Scrobbles **once**, source-agnostic (correct). |
| **The "unified" state you see on Home** | A **client-side display fold** (most-recent-`lastPlayedAt` wins). Looks consistent; the servers themselves stay divergent. |

### The concrete bug R5 (Opus 4.8 max) reproduced — this is the whole argument
> Watch 4 min of *Dune* on **Plex** (Plozz reports to Plex only). Open the merged
> card — the hero shows "4 min" (the unified fold sees Plex's recent timestamp).
> Best-source auto-pick chooses the **Jellyfin** copy (better direct-play). Press
> Play → resume comes from *Jellyfin's* `resumePosition` = **0** → **it starts from
> the beginning**, even though the card said 4 min. Jellyfin never learned about the
> 4 minutes.

So the display (unified fold) and playback reality (per-server resume) **disagree**,
and the only thing papering over it is that you keep returning to the same server,
online, in this one app. Open the official Plex app and it's right; open anything
pointed at Jellyfin and it's wrong. **That is your pain, root-caused.**

### Consensus policy — "Convergent watch-state" (write-through + outbox)
**Principle: the client is the only thing that knows the truth (you watched 4 min).
Treat every server as a replica to converge — best-effort, durable. Default ON.**

**Throttling (everyone independently landed on the same shape — don't hammer N
servers every 10s):**
| Event | Launch (primary) server | Other servers holding the title |
|---|---|---|
| progress tick (~10s) | report (existing cadence) | **nothing** |
| seek end | report | nothing |
| **pause / stop** | report | **fan out resume position** |
| every ~60s continuous play | (already covered) | **one coarse batched checkpoint** |
| **finish (≥~90%)** | report | **fan out `setPlayed(true)` + clear resume everywhere** |
| app foreground / reachability | — | **drain retry queue / reconcile** |

The ~60s checkpoint + lifecycle-boundary fan-out is the agreed compromise: casual
"walk away" propagates within a minute; servers and their Trakt plugins aren't spammed.

**The single highest-leverage fix (R5, smallest change, ship first):** at Play time,
seek to the **unified furthest position regardless of which server backs the stream**
(pass an explicit `resumeOverride = unifiedWatchState.resumePosition` into the player),
and report it to the chosen server on entry so it converges immediately. This alone
makes "card says 4 min → Play resumes at 4 min" true even when best-source routes to a
different server.

**Conflict resolution (consensus):**
- **Display:** keep most-recent-`lastPlayedAt` wins (already correct).
- **Writes/convergence:** **furthest progress wins** for resume; **`isPlayed` / ≥90%
  always wins** and clears resume; **explicit unwatch (newest) wins** over an older
  played flag; **monotonic/epsilon guard** so a late stale report can't rewind you
  ("resume creep"). A user-set primary server breaks true ties. *(R1/R4 add an optional
  vector/logical clock keyed by identity, since server timestamps drift — worth it if
  you go all-in on the ledger.)*

**Durability — the part that makes it real (R1, R4, R5):** a small **persisted
watch-state outbox**. Every fan-out write is enqueued `(accountID, itemID, position,
played, ts)`, flushed on success, **retried on next reachability/launch**, coalescing
duplicates. *Without this, "stays watched" is a lie the first time a server is asleep
when you stop.*

**New capability needed:** `WatchStateProviding` today is only `setPlayed(Bool)`. To
sync a resume *position* to a non-played server you need a session-less position write
(R1/R4 propose `ResumeStateWriting.setResumePosition`). Jellyfin has the progress/UserData
endpoints; Plex has `/:/timeline` and `/:/progress`.

**Trakt double-count avoidance (consensus):** keep scrobbling **once** from the player
(never fan Trakt out — it's account-level). The real risk is a **server-side
Jellyfin/Plex Trakt plugin** *plus* Plozz both scrobbling when Plozz fans out writes.
Fix = an explicit ownership setting **"Trakt scrobbling: Plozz (default) / My servers
handle it"**, shown only when Trakt is connected, with a warning if a server-side
plugin is detected. **Every branch flagged validating this first** — it gates the whole
design.

**Settings UX (keep it to ~2–3 switches, defaults ON):**
- **Keep watch progress in sync across all my servers** — default **ON** ("watch on
  any server, see it everywhere"). Off = launch-server-only — *this is your opt-out.*
- **Count as a play on every server** — default **ON** (some purists turn this off to
  avoid inflating per-server play counts while still syncing resume).
- **Trakt scrobbling: Plozz / My servers** — only when Trakt is connected.

> **Directly answers your question:** Yes — count it as a play on **both** by default,
> with a one-switch opt-out to a single server. Resume + watched then survive
> best-source routing, other devices, and offline servers.

---

## 3. Differentiation — how Plozz stands out (lean into the seam, don't copy Infuse)

Ranked by how copy-resistant each is (highest moat first). Bolded = named by most/all
branches.

1. **Convergent watch-state as the headline promise** *(all 5)* — *"Your place follows
   you across every server and device — guaranteed."* JellyPlex/Trakt solve this
   out-of-band with cron jobs and 15-min lag; Plozz does it inline. This is the
   flagship and it's just §2 productized.
2. **Seamless mid-stream cross-server failover** *(all 5)* — "RAID for streaming." A
   server stalls/dies → transparently switch to another server's copy at the same
   position (the merged card already holds every server's `MediaSourceRef`). Today
   failover only crosses *engines/transcode*, never *servers*. The most viscerally
   impressive demo Plozz can give. **Gate behind a spike** — keyframe/seek alignment
   across different copies is the hard part (R4/R5 caution).
3. **Source racing / best-source auto-pick** *(all 5)* — at Play, probe all hosting
   servers in parallel; start on the fastest **direct-play** stream (LAN > WAN, direct
   > transcode), prefer the copy this exact Apple TV plays without transcoding. The
   measurable "fastest tvOS player" claim. Add **health/bandwidth signals** (per-server
   latency, recent failure rate) and a per-source **"Direct Play ✓ / Will Transcode"**
   hint in the picker (R2 "Source Brain", R3 "codec arbitrage", R5 "health-aware").
4. **Cross-server resume carry / threaded Continue Watching** *(R1/R4/R5)* — finished
   S1E1 on Plex but S1E2 only exists on Jellyfin? Continue Watching threads the next
   episode across the seam; yesterday's phone-on-Plex progress flows into tonight's
   Jellyfin play. Falls out of §2 for free.
5. **Cross-server edition/version picker** *(R5, your original ask)* — `EditionParser`
   already exists; merge versions *across servers* into one picker: *"Theatrical
   (Jellyfin) · Extended 4K Remux (Plex) · Director's Cut (Jellyfin)."* The user picks
   an **edition**; Plozz picks the **server**. Directly addresses your "make the
   version picker clearer than just resolution + play method."
6. **Library/availability health view** *(R1 "Vault", R5)* — only a multi-server client
   can show "on 3 servers · 2 online", what's single-copy and at risk, what's redundant
   and wasting disk. Pure prosumer differentiation.
7. **Honorable mentions:** user-taught identity graph (§1, also a differentiator);
   home/away network awareness; predictive prefetch of best-source `playbackInfo` on
   focus → "no loading spinners"; automatic engine routing (native AV for HDR/DV +
   efficiency, MPV only for codecs AV can't touch).

**The bolder, more divergent bets (weigh, don't necessarily adopt):**
- **R4 — Family/Profile Bridging:** one Plozz profile → N server users (kids' Jellyfin
  user + kids' Plex managed user), unified history/restrictions.
- **R4 — Disposable Mirror Mode:** a privacy toggle that writes to *no* server (history
  stays local only). No competitor ships this; solves the "rewatched something
  embarrassing, now it's in my Plex history forever" complaint. Cheap once the local
  ledger exists.

**Where NOT to spend (consensus):** offline-download/local-cache library (Infuse's
Library-Mode turf, against the live wedge), and a global Library/Direct mode toggle.

---

## 4. The one genuine disagreement — control vs opinionation

| | **R4 (Opus 4.7) — purist** | **R2 (Codex) — steerable** | **R1/R3/R5 — middle** |
|---|---|---|---|
| Per-server visibility | Diagnostics-only toggle, QA use | First-class **Source Lens** | Filter facet / quality chip |
| Merge transparency | Invisible; just works | **Confidence tiers + "Why merged?"** | Badge + soft-link affordance |
| Watch-state truth | Plozz is canonical ledger, full stop | Primary-live + secondary checkpoints | Canonical ledger + outbox |
| Risk called out | Configurability dilutes the product | Invisible automation erodes trust | — |

This is the real decision for you: **how much of the cross-server machinery to expose.**
Everyone agrees on unified-default + sync-on-by-default; they differ on whether power
users get visible lenses/confidence UI (R2) or whether that clutter betrays the
opinionated "it just works" product (R4).

---

## 5. Recommended sequencing (merged across all 5 — value-to-risk order)

Each step is independently shippable; earlier steps are smaller and de-risk the later
ones.

1. **Resume reconciliation at Play** *(the bug fix)* — seek to the unified furthest
   position regardless of source; report it to the chosen server on entry. Smallest
   change; immediately makes "see 4 min → resume at 4 min" true. **Do this first.**
2. **Progress fan-out + throttle** — add a session-less progress/resume write to
   `WatchStateProviding`; fan out on pause/stop/finish + ~60s checkpoint; keep 10s to
   the launch server.
3. **Watch-state outbox** — persisted retry queue with reachability flush + coalescing.
   Turns best-effort into durable convergence ("stays watched" becomes true offline).
4. **Settings** (2–3 toggles, defaults ON) + **Trakt ownership toggle**.
5. **Conflict-resolution hardening** — furthest-wins, played-wins, monotonic guard;
   extend the existing `unifiedWatchState` tests with out-of-order arrival cases.
6. **Cross-server mid-stream failover** — *after a spike* proves keyframe/seek alignment
   is invisible. Uses #2's coordinator + existing `MediaSourceRef` set + `CrossSourceSelector`.
7. **Health/bandwidth-aware best-source** + per-source Direct-Play hint.
8. **User-correctable identity** (soft-link tier + persisted overrides) — closes the
   series-missed-merge gap; **persisted identity cache** for instant cold launch.
9. **Differentiation polish** — cross-server edition picker, availability/health view,
   predictive prefetch, threaded cross-server Continue Watching.

---

## 6. What to validate before building (gating experiments, from all 5)

1. **Trakt double-count** with server-side Jellyfin/Plex Trakt plugins enabled — watch
   one title, count the scrobbles. **Gates the entire §2 design.**
2. **Write amplification / rate limits** under fan-out across 3–5 servers (esp. Plex
   `/:/timeline`) — confirm the boundary + 60s cadence stays under limits.
3. **Session-less resume write correctness** — does Plex `/:/progress` register without
   an active play session? Does Jellyfin UserData write take?
4. **Cross-device acceptance test** — watch on Plozz → confirm the *official Plex app*
   and a *Jellyfin web client* both reflect the new position within seconds. This is
   the only test that proves convergence is real, not another fold.
5. **Failover seek accuracy** on a one-day spike with two known-good copies of the same
   title — if it can't get under ~400ms with no visible glitch, defer shipping it
   visibly.
6. **The soft-link identity UX** with real users — the "1 possible match" affordance is
   the most fragile UI call in the whole proposal.

---

## 7. Open questions for Brandon

1. **Control philosophy (the §4 split):** invisible "it just works" (R4), or
   power-user lenses + "Why merged?" transparency (R2)? This shapes a lot of UI.
2. **How far to take the ledger:** simple write-through + outbox (ships fast), or a
   full local canonical `WatchLedger` with logical/vector clocks (more robust against
   server clock-skew, more work)? R5's bug fix #1 is valuable either way.
3. **Default for "count as a play on every server":** ON for everyone, or ON for resume
   but OFF for play-count on shared/guest servers?
4. **Failover ambition:** is "RAID for streaming" a brand-defining bet worth the spike
   now, or a later differentiator after convergence ships?
5. **The bold divergent bets:** any appetite for Family/Profile Bridging or Disposable
   Mirror Mode, or keep scope on the core cross-server convergence first?

---

## 8. Addendum — Server-defined rows & customizable Home

> **Added in a second research pass** answering a specific Brandon question the
> original 5 branches did not cover: *most users have only one server, and Plex/
> Jellyfin already expose user playlists, collections, and (Plex) curated hubs that
> Plozz throws away today. Should we surface those, how, and should Home be
> customizable?* Run the same way — **3 independent branches, same brief, different
> models, no knowledge of each other:**
>
> | # | Model | Branch | One-line thesis |
> |---|---|---|---|
> | S1 | Opus 4.8 (high) | `thatcube-home-rows-strategy-research` | Surface **user-authored containers** (playlists+collections) as rows; server hubs are **signals, never rows** |
> | S2 | GPT-5.3-Codex (xhigh) | `thatcube-srvrows-r2-codex` | **Unified-first + opt-in row catalog** that *may* include selective server rows (incl. Plex hubs) |
> | S3 | Gemini 3.1 Pro (high) | `thatcube-scaling-enigma` | **Lenses, not server mirrors** — pin curated entities (playlists, collections, *promoted* hubs) |

### 8.1 What all three independently agreed on

1. **Plozz owns the Home layout — always.** No branch wants to mirror a server's
   home feed. Jellyfin doesn't even *have* a server-defined layout (it's a client
   preference), and mirroring Plex's would re-introduce the banned "server as
   layout" and be unmatchable on Jellyfin. Plozz synthesizes the layout; servers
   contribute *content for* rows, never the row arrangement.

2. **One unified row abstraction, multiple source kinds.** A playlist, a collection,
   and a built-in (Continue Watching) all render as the same `HomeRow` UI concept.
   Parity is achieved at the **UX layer**, not by fabricating fake "Jellyfin hubs."

3. **Cards inside every row still pass through `MediaItemMerger`.** This is
   unanimous and non-negotiable: a Plex-sourced playlist row can contain a card
   that plays from Jellyfin if that's the better source. The row is a *discovery
   vector*; card identity stays globally unified with the source picker intact.

4. **Rows are distinct by default; no aggressive auto-merge of rows.** Built-ins are
   global singletons; user containers are source-scoped identities. (S1/S3 allow an
   *optional* high-confidence same-name row merge; S2 says keep them distinct. All
   three agree the safe default is **distinct**.)

5. **Customizable Home lives Plozz-side, per-profile** — generalize the existing
   `HomeLibraryVisibilityStore` into a `HomeLayoutStore` holding an ordered list of
   row configs (id, visible, sortIndex). It *must* be Plozz-side: Jellyfin has no
   server layout, Plex's is per-server, and Plozz is the unified layer.

6. **One model for N=1 and N>1 — the difference is defaults, not code.** This is the
   key unlock for Brandon's "most people have one server" point: the strategy is
   **user-content-centric, not cross-server-centric**, so it's valuable even when
   the cross-server merge is a no-op. For N=1 it finally surfaces the playlists/
   collections we discard today (the most valuable thrown-away data); for N>1 the
   same rows simply span servers.

7. **Reject Infuse's "show every row."** On tvOS every extra row is a D-pad tax →
   "row soup." Built-ins visible by default; discovered server rows are **opt-in**
   and promotable.

### 8.2 The one genuine disagreement — what to do with Plex's algorithmic/promoted hubs

The branches split on a clean spectrum, exactly mirroring the §4 control-vs-
opinionation tension:

| | **S1 (Opus) — purist** | **S3 (Gemini) — middle** | **S2 (Codex) — permissive** |
|---|---|---|---|
| User playlists + collections as rows | ✅ yes | ✅ yes | ✅ yes |
| Plex **functional** hubs (Continue Watching, Recently Added) | ❌ Plozz already synthesizes these globally | ❌ reject — synthesize globally | ❌ avoid duplicating built-ins |
| Plex **promoted/pinned** hubs (admin/user-curated) | ❌ **signals only**, feed a future "For You", never passthrough | ✅ elevate as a pinnable Lens | ✅ allowed as an optional row |
| Why | Hub passthrough = server-as-layout creeping back + Jellyfin can't match → asymmetry returns | Promoted hubs *are* curation, not layout | More user choice; let defaults tune it |

**Synthesis recommendation:** Ship the **symmetric, unanimous layer first**
(user-authored playlists + collections), and **defer hubs**. When/if hubs come, take
the **Gemini middle** but with the **Opus guardrail**: only *promoted/pinned* hubs
(never the functional CW/Recently-Added we already synthesize), and prefer treating
them as **signals into a Plozz-synthesized "For You"** rather than raw passthrough —
so we never hand Jellyfin a row type it structurally cannot offer.

### 8.3 Answers to Brandon's questions a–e

- **(a) Surface server rows at all?** Yes, *selectively and opt-in* — user-authored
  containers, not the whole server feed. Built-ins stay the curated anchors.
- **(b) How, given the asymmetry?** One `HomeRow` abstraction with a typed source
  (`.system`, `.playlist`, `.collection`, and *later* `.promotedHub`). Plex and
  Jellyfin playlists/collections render through the same door; no invented
  "Jellyfin hubs." Plex-only promoted hubs (if enabled) are a distinct source type,
  not forced into false parity.
- **(c) Cross-server dedup:** **Cards always merge** (existing identity logic);
  **rows stay distinct by default**, with an *optional* high-confidence same-name
  merge the user can accept/split. A Plex promoted hub with no Jellyfin twin is a
  valid standalone row.
- **(d) Customizable Home model:** an ordered `[HomeRowConfig { rowID, isVisible,
  sortIndex }]` persisted Plozz-side per-profile (generalize
  `HomeLibraryVisibilityStore` → `HomeLayoutStore`); an "Edit Home" sheet lists all
  available rows (built-in + discovered) to toggle and reorder. Default order:
  Continue Watching, Latest, Watchlist, then libraries.
- **(e) N=1 vs N>1:** one engine, **defaults differ** — N=1 surfaces more server-
  curated rows by default (rich, personal Home, solves the "empty Home" feeling);
  N>1 is conservative-by-default to avoid soup, with the same opt-in catalog.

### 8.4 Reconciling §1's "server is never a browsing axis"

A user-defined row is **content/curation, not topology.** "Everything on Server X"
is a browsing axis (banned). "The playlist I built" is a content list — *exactly the
precedent the existing Watchlist row already sets.* We preserve the rule by: stripping
server names from row titles, never adding a Plex/Jellyfin tab or mode, keeping the
server as a card chip + source picker only, and routing every card through the unified
merger. **The server hands us a list of IDs, not a playback silo.**

### 8.5 Concrete data model & provider fetches (precise on existing vs net-new)

**Model** (converged from all three):
- `HomeRow` / `HomeRowDescriptor { id, kind, source, title, defaultRank, enabled }`
- `HomeRowSource`: `.system` · `.playlist(accountID, provider, id)` ·
  `.collection(accountID, provider, id)` · *(deferred)* `.promotedHub(accountID, id)`
- `HomeAggregator.Content` moves from **4 fixed fields**
  (`continueWatching/latest/watchlist/libraries`) → **`rows: [HomeRow]`**.
- Additive provider capability `HomeContainersProviding { playlists, collections,
  containerItems }`, mirroring the existing optional `WatchlistProviding` pattern.

**Fetches — accurate to the current codebase:**
- **Jellyfin** = *generalize one existing fetch + add two list endpoints* (not
  greenfield): `userViews` (library list) and `playlistItems` (one playlist's items,
  currently music-only) already exist; **net-new** = list playlists
  (`/Items?IncludeItemTypes=Playlist&Recursive=true`), list collections
  (`IncludeItemTypes=BoxSet&Recursive=true`), and lifting the item fetch out of the
  music path.
- **Plex** = *fully greenfield*: today only `onDeck` + `recentlyAdded` exist;
  **net-new** = `/playlists` + `/playlists/{id}/items` and
  `/library/sections/{id}/collections`. (Hubs `/hubs` deliberately **not** wired as
  rows in phase 1.)

### 8.6 Top risks (and the sharp one to not miss)

1. **Row soup** → containers are opt-in, built-ins are the default anchors.
2. **Launch latency** from extra endpoints → fetch row *lists* eagerly, row *items*
   lazily; behind a flag initially.
3. **⚠️ Ordered-row interleave bug (S1's catch):** the current cross-server merge
   uses **round-robin interleave**, which is correct for CW/Latest but **wrong for an
   ordered playlist** — it would scramble the user's deliberate order. Ordered rows
   must use **in-place dedup that preserves the source order**, not interleave.
4. **Stable row identity** across reload/rename (don't lose the user's pin when a
   playlist is renamed server-side).
5. **Smart vs dumb Plex playlists** (DTO shape differences) and **collection
   double-listing** vs the per-library tiles.

### 8.7 Recommended sequencing (value → risk)

1. **`HomeRow` abstraction + `HomeLayoutStore`** (generalize
   `HomeLibraryVisibilityStore`); migrate `HomeAggregator.Content` to `rows: [HomeRow]`
   with today's built-ins as the default rows. *No new network — pure refactor, de-risks
   everything after.*
2. **Playlists as opt-in rows — Jellyfin first** (smaller lift), then Plex. Biggest
   N=1 win, smallest risk. Apply the ordered-row dedup (not interleave).
3. **Collections as rows** (both servers).
4. **"Customize Home" UI** — show/hide/reorder, persisted per-profile.
5. **Optional, later:** cross-server same-name row merge + manual split; and a Plozz-
   synthesized **"For You"** from Plex promoted-hub *signals* (never raw passthrough).

### 8.8 Open questions for Brandon (this section)

1. **Hubs:** agree to **ship playlists+collections first and defer Plex hubs**? And
   when hubs come, the "promoted-only, as *signals* into a Plozz 'For You'" guardrail
   — or would you rather pass promoted Plex hubs straight through as rows (simpler,
   but asymmetric vs Jellyfin)?
2. **Default density:** for a 1-server user, how aggressive should the *default* be —
   auto-surface their playlists/collections, or keep Home minimal and make everything
   opt-in via "Edit Home"?
3. **Row merge:** when the same-named collection exists on two servers, default to
   **two distinct rows** (safe) or **one merged row** with a split affordance?

---

*Full individual proposals (with code citations, trade-off tables, and per-branch
implementation sketches) are preserved in each research branch's `plan.md`. Branches:
`thatcube-strategy-research-opus48`, `thatcube-strategy-r2-codex-5-3-xhigh`,
`thatcube-didactic-dollop`, `thatcube-strategy-r4-opus-xhigh`,
`thatcube-strategy-research-r5`; §8 addendum: `thatcube-home-rows-strategy-research`,
`thatcube-srvrows-r2-codex`, `thatcube-scaling-enigma`.*
