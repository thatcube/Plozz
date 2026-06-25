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

8. **🔒 HARD INVARIANT — server rows carry *membership*, never *state*.** A server-
   defined row contributes only its **membership/order-intent** (which items were
   curated); its baked-in per-item **state** (progress, watched, unwatched-count) is
   **never trusted** — every item's state is re-projected through Plozz's unified
   watch-state fold (the `MediaItemMutation` bus) before display. This is the bridge
   between the rows feature and the §2 watch-state-correctness work: without it you
   get a live on-screen contradiction (a Plex "Continue Watching" hub showing 4 min
   next to our synthesized row showing finished because it was watched on Jellyfin —
   the row-level form of §2's "illusion breaks" bug). Two direct corollaries:
   **(i)** never ingest/mirror a server row of a *kind Plozz already synthesizes*
   (Continue Watching / Recently Added / Next Up) — ingest only editorial membership
   (playlists/collections) and re-fold state; **(ii)** two refresh clocks —
   membership cached slowly (snapshot for zero-spinner first paint), state recomputed
   on every appearance; an offline server's rows drop gracefully and never block Home.
   *(Detail and the freshness tiebreaker in §8.9.6.)*

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

### 8.9 Originals' reactions — the deep-context theses weigh in

After the 3 fresh branches above, the **5 original strategy-doc authors** reacted to the
same question *through their own theses* (kept distinct, not consensus-merged). They
**ratify §8.1's consensus** and add real refinements:

| # | Model | Thesis lens | Distinct contribution here |
|---|---|---|---|
| R1 | Opus 4.8 high | truth layer / own the seam | **"Curation is an axis, server is not"**; *curation-resurrection* is the N=1 headline; conservative confirm-only row merge |
| R2 | Codex xhigh | unified-by-default | **"Ingest many, render few"** budgeted pipeline; richest row schema; keep human-curated rows distinct |
| R3 | Gemini 3.1 | smart client, dumb pipes | **"Data vs Dictate"** (respect user data, reject server layout dictate); aggressive row merge; **iCloud KV sync** of layout |
| R4 | Opus 4.7 xhigh | Title OS | **First-run import policy should differ by server count** (N=1 aggressive, N>1 curated) + one "Mirror vs Curated" toggle |
| R5 | Opus 4.8 max | control plane | **T1/T2/T3 tiering** + anti-duplication guardrail; the **de-servered row litmus test**; found a real CW bug |

**The reconciliation is now unanimous across all 8** and stated most crisply by R5's
**"de-servered row test":** strip the server's name off a row — if it still means
something ("Noir Classics", "Dad's Playlist") it's **curation** → ingest it de-servered
into one Home; if it only means "Everything on Plex" it's a **browsing axis** → reject.
Curation is an axis; the server is not. This *sharpens* §1 rather than contradicting it.

**Refinements that materially improve §8 (adopted into the recommendation):**

1. **Tier the rows (R5) — and a hard guardrail.** Three tiers, treated differently:
   - **T1 algorithmic/temporal** (Continue Watching, Recently Added): Plozz already
     synthesizes these cross-server + deduped. **GUARDRAIL: never ingest a server row
     whose kind Plozz already synthesizes** — otherwise a Plex "On Deck" row sits next
     to our synthesized Continue Watching (duplicate-row trap). Suppress temporal/
     algorithmic hub kinds; ingest only *editorial* kinds.
   - **T2 user-authored** (the user's own playlists + collections): highest signal,
     explicit intent → **surface by default**.
   - **T3 admin/server-promoted hubs** ("Oscar Winners", "Trending"): medium value,
     admin's voice → **opt-in, capped.**
   This dissolves the "row-soup vs ignore" binary and gives a principled default.

2. **A real bug R5 found while grounding (independent quick win):** our Continue
   Watching is *already* asymmetric — Jellyfin uses `/Users/{id}/Items/Resume`
   (in-progress only) and **omits Next Up** (`/Shows/NextUp`), whereas Plex
   `/library/onDeck` *does* surface the next unwatched episode. Fix: fold Jellyfin Next
   Up into the **synthesized** Continue Watching as an input (render once, no separate
   "Next Up" row). This is shippable *before* any rows work and immediately improves
   N=1 Jellyfin users. *(Logged for the backlog regardless of the rows decision.)*

3. **Use an optional capability protocol (R5/R1):** `CuratedRowsProviding` detected via
   `as?`, exactly like the existing `WatchStateProviding` / `WatchlistProviding` /
   music-provider pattern. Plex implements hubs+playlists+collections; Jellyfin
   implements playlists+collections(+NextUp). Idiomatic to the codebase, keeps the
   asymmetry inside capability detection instead of the Home model.

4. **"New rows available" tray (R1), not auto-injection:** server rows discovered after
   the user has arranged their Home appear in a tray to add — never silently injected
   into a layout they curated.

5. **Layout storage:** all 8 agree it's **Plozz-side per-profile** (generalize
   `HomeLibraryVisibilityStore` → `HomeLayoutStore`). R3 wants it **iCloud-synced now**
   (`NSUbiquitousKeyValueStore`); the majority say device/profile-local first, CloudKit
   later. *Recommendation: ship local, design the store so iCloud KV is a drop-in later.*

6. **Split row *membership* from row *state* (R5 — connects this to §2).** A server row
   carries two separable things: **(a) membership/order-intent** (which items the
   user/server curated — trust the server) and **(b) per-item state baked in** (progress,
   watched, unwatched-count). §2 proved per-server state is stale/divergent. **Rule:
   ingest a row's membership from the server, but re-project every item's state through
   Plozz's unified fold before display** — never let a server row's embedded state win.
   This is *why* the T1 guardrail matters: ingesting Plex's "Continue Watching" hub
   verbatim would show 4 min next to our synthesized CW showing finished — the row-level
   form of §2's "illusion breaks" bug. Two refresh clocks follow: **membership** changes
   rarely → cache aggressively, persisted snapshot for zero-spinner first paint, lazy
   background refresh (reuse HomeAggregator's offline-source-drop resilience); **state/
   order** is volatile → recompute on every appearance and subscribe rows to the existing
   `MediaItemMutation` optimistic bus so marking watched / reporting progress instantly
   re-projects them with no refetch. (This also gives the row-merge a **freshness
   tiebreaker**: when merging T2 rows, order by playlist `updatedAt` most-recent-wins
   where available, else union.)

**Where they genuinely diverge — the two decisions for Brandon:**

| Decision | Aggressive ⟵ | | ⟶ Conservative |
|---|---|---|---|
| **Cross-server ROW merge** (same-named playlist/collection on 2 servers) | R3: merge aggressively by name | R1/R5: merge **T2 only**, conservative, **confirm-only** (title+kind, like series identity) | R2/R4: **keep distinct** by default + one-tap "merge these rows" |
| **Default density / promoted hubs** | R4(N=1): aggressively auto-import playlists+collections+hubs so it "feels complete minute one" | R1/R5: default-on **user-authored only**; promoted hubs **opt-in, capped** | R4(N>1): only synthesized rows by default, everything else behind "Discover more rows" |

On **row-merge**, 4 of 5 originals (R1, R2, R4, R5) land at **distinct-by-default**
(merge only conservatively, user-confirmable, T2-only) — only R3 wants aggressive merge.
**Updated §8.3(c) recommendation: keep rows distinct by default; offer conservative,
confirm-only merge of user-authored rows; never auto-merge T1/T3.**

On **density**, the synthesis is **R4's server-count-adaptive defaults**, scoped by R5's
tiers: **T2 user-authored rows default-on** (this is the N=1 "curation-resurrection"
that every Opus branch calls the headline win); **T3 promoted hubs opt-in**; for N>1,
tighten the default budget and lean on Plozz's cross-server synthesis. A single
"Mirror my server's home ⟷ Curated" toggle (R4) exposes the spectrum without forking
the model.

**Net updated recommendation (all 8):** ship the unanimous, symmetric core first —
**T2 user-authored playlists + collections as de-servered rows in a Plozz-owned,
per-profile, customizable Home**, with the T1 anti-duplication guardrail, cards always
merged but **rows distinct by default**, and **server-count-adaptive defaults**. Defer
T3 promoted hubs (opt-in, later) and any aggressive row-merge. Land R5's Jellyfin
Next-Up fold-in as an independent quick win.

---

## 9. Addendum — First-time setup & onboarding

> **Third research pass** answering Brandon's onboarding question: *first-time setup needs
> love — a first-run APP flow (fresh install) that bundles a per-server flow (runs on every
> server add), better profile opt-in/out, maybe a theme step. KEY PRINCIPLE he set: adding a
> server ALWAYS imports the whole server; onboarding choices are purely about Home-page
> PRESENTATION, never data availability — so "pre-check vs opt-in" is a presentation-default
> question, not a data question.* Run the same way — **3 independent blind branches:**
>
> | # | Model | Branch | One-line thesis | Stance on the core question |
> |---|---|---|---|---|
> | O1 | Opus 4.8 high | `thatcube-onboarding-research-opus48` | "Onboarding picks an **identity, not a layout** — ship a great Home, don't make users assemble one" | **Reject the checklist**; keep opt-**out**, 1-tap subtractive "Trim" reveal |
> | O2 | GPT-5.3-Codex xhigh | `thatcube-onboarding-r2-codex` | "A fast **Home-presentation seed**, not a content gate" | **Smart server-count-adaptive** defaults + one-tap "Use recommended" |
> | O3 | Gemini 3.1 high | `thatcube-jubilant-couscous` | "Onboarding is a **Curation Wizard**, not a settings menu" | **Strict opt-in** (none checked); migrate store to default-invisible |

### 9.1 What all three independently agreed on

1. **One reusable per-server component, two contexts.** Whatever the per-server step is, it's
   *the same view* in first-run and in later "add 2nd/3rd server" (from Settings) — O1
   `ServerHomeReveal`, O2 `HomePresentationSetupFlow`, O3 `ServerCurationView(mode:)`. Inputs:
   active profile + all resolved accounts + the newly-added account IDs; output: a layout
   patch into `HomeLayoutStore`.
2. **Cross-server choices are presented DE-SERVERED and deduped.** The step lists content
   families ("Movies · 3 sources", "Dad's Playlist"), server shown only as a metadata chip —
   **never** server sections/tabs. A library/playlist on 3 servers is chosen **once** (reuse
   AggregatedLibrary same-name merge + §8 row-identity). This keeps §1/§8's "server is never a
   browsing axis" intact *inside onboarding*.
3. **Don't gate first playback behind a wizard.** All three protect the "fast" brand: a 1-tap
   "recommended/looks-good" path; advanced curation deferred to Settings.
4. **Profiles = a single binary, never a forced wizard.** "Just me" (default → profiles off,
   no startup picker) vs "Multiple people" (→ profiles on + ask-on-startup). Home layout is a
   **per-profile** namespace; a new profile seeds from a **copy of the default layout**, not
   blank. (O1 goes furthest: don't even ask — surface profiles *only* when Plex auth detects a
   multi-user Plex Home.)
5. **Theme = lightweight, skippable, editable later.** All three would surface the existing
   `ThemeSettingsStore` as a one-screen onboarding card; none lets it add real friction.
6. **Persist Plozz-side with a first-run-complete flag + resume.** Add `firstRunCompleted` and
   make the flow resumable if the user backs out mid-setup; Home choices live in the per-profile
   `HomeLayoutStore`, theme in `ThemeSettingsStore`, flags in `UserDefaults`.

### 9.2 The core disagreement — pre-check vs opt-in vs reveal (a clean spectrum)

This maps directly onto the existing §4 control-vs-opinionation tension:

| | **O3 (Gemini) — opt-in** | **O2 (Codex) — smart middle** | **O1 (Opus) — opt-out / reveal** |
|---|---|---|---|
| Default check state | **Nothing checked**; user adds rows | **Server-count-adaptive**: N=1 pre-select libraries + capped playlists; N>1 only net-new families, opt-in | **Everything ON**; optional **subtractive "Trim"** |
| Is it a gate? | Yes — a required curation step | Soft — "Use recommended" 1-tap | **No — a 1-tap reveal, never a gate** |
| `HomeLayoutStore` default | **Invisible** (migrate to opt-in) | **Explicit** row configs (migrate legacy excluded-keys → explicit visible/order) | **Visible** (keep opt-out; store hidden ids; new libs auto-appear) |
| Risk it accepts | Empty-Home if users skip (mitigates w/ "Select All" + empty-state CTA) | Migration complexity; "recommended" must be good | Less user control up front (relies on Settings → Edit Home later) |
| Brand fit | Most "intentional", most friction | Balanced | Fastest, most "it just works" |

**My recommendation (synthesis):** lean **O1's "reveal, not gate" UX** wrapped around **O2's
server-count-adaptive defaults** — and **reject O3's strict global opt-in.** Rationale:
- The KEY PRINCIPLE (full server always imported) makes **default-ON the honest default** —
  hiding is the exception, so the UI should be **subtractive** (O1), not a checklist that makes
  you approve N rows before seeing a poster.
- O3 itself flags the **empty-Home risk** of strict opt-in; that directly fights the "fast,
  great out-of-box Home" brand and the App-Store first-impression.
- But O1's pure default-everything is improved by O2's **N>1 restraint**: when you add a 2nd/3rd
  server, *don't* re-flood a Home the user already arranged — surface only **new, deduped**
  families (default-on for N=1; opt-in for the N>1 add). This is exactly §8's
  server-count-adaptive principle applied to onboarding.
- Net: **N=1 → everything on, 1-tap into Home, trim later; N>1 add → only net-new deduped rows
  offered.** Opt-out semantics preserved; row-soup prevented by §8 tiers (T2 default-on, T3
  deferred), not by forcing opt-in.

### 9.3 Answers to Brandon's 7 questions

1. **First-run sequence:** `welcome (skip) → theme (1 screen, skippable, pre-auth) → add+auth
   first server (the only required step) → per-server reveal (1-tap "Looks good" / "Trim") →
   Home`. Profiles are **not** a forced step (ask only on multi-user detection, or as O2's single
   binary if you prefer an explicit prompt). Time-to-first-playback stays well under ~30s.
2. **Per-server flow:** a **reveal**, not a checklist — default-ON + subtractive trim for N=1;
   net-new deduped families for N>1 adds. (See §9.2.)
3. **Nesting / reusable component:** one component, three chromes — full-screen (first run),
   non-modal Home banner/sheet (later add, never gates the app), and Settings → Edit Home. It
   degrades to **libraries-only** until §8's `CuratedRowsProviding` lands (so onboarding does
   **not** block on the §8 rows work).
4. **Profiles:** single binary, no wizard before playback; per-profile Home; new profile seeds
   from a copy of the default layout. O1's "detect Plex Home multi-user → one dismissible prompt"
   is the lightest-touch option; O2/O3's explicit "Just me vs Multiple" is the more discoverable
   one — a Brandon call (see §9.6).
5. **Theme:** yes as **step 0**, pre-auth, one screen, skippable; demote to a Settings nudge if
   it ever feels like delay.
6. **State/persistence:** prefer **not** to bloat `SessionState` with a fragile step cursor.
   Two viable shapes: O1's **fact-derived** `FirstRunCoordinator` (derive stage from
   `themeChosen` + persisted `accounts` + `revealedAccountIDs` + `firstRunCompleted`; naturally
   idempotent on resume) vs O2/O3's **explicit phase enum** extension
   (`welcome/theme/profile/…/homeSetup` + resumable `inProgressPhase`). Recommendation: the
   **fact-derived** approach — it makes back-out/resume free and avoids new state-machine edge
   cases. Persist Home per-profile in `HomeLayoutStore`.
7. **§8 reconciliation:** the reveal groups by **content type**, strips server names, dedups
   per-server copies, and only ever toggles a **de-servered identity** — never "all of Server X
   as a row." Hubs (T3) are deferred, so onboarding stays opt-out/default-on without
   re-introducing server-as-layout.

### 9.4 Resolving the opt-out↔opt-in conflict (the migration all three had to face)

Today `HomeLibraryVisibility` is **opt-out** (libraries default-visible, store the *excluded*
ids). The three split exactly on whether to keep that:
- **O1 keeps opt-out:** `HomeLayoutStore` stores *hidden* ids; unknown/new rows default visible.
- **O3 flips to opt-in:** migrate the store to **default-invisible**; only explicitly-added rows
  show. (Required by its strict-opt-in thesis.)
- **O2 makes it explicit:** absorb legacy excluded-keys into **explicit `HomeRowConfig
  {rowID, visible, order}`**, translating current users' exclusions into explicit visibility and
  seeding new installs from onboarding defaults.

**Recommendation:** **O2's explicit-config store, seeded to preserve opt-out behavior** (new/
unknown rows default **visible**). This is the safe superset: it keeps today's behavior for
existing users (no surprise-hidden libraries on upgrade), supports O1's reveal (defaults on,
trim writes explicit `visible:false`), *and* can express O3's opt-in for anyone who wants a
minimal Home — without forcing the empty-Home default on everyone.

### 9.5 Top risks & recommended sequencing

**Risks:** (1) the reveal scope-creeps into a wizard → enforce 1-tap, full-screen only on first
run; (2) onboarding blocks on §8 → the component must degrade to libraries-only; (3) store
**migration regressions** (don't hide libraries users currently see) → migrate to a
behavior-preserving explicit store with tests; (4) strict opt-in → empty Home (the reason to
avoid O3's default); (5) profile prompt misfire → offer, never auto-create; (6) theme-before-auth
delay → one skippable screen.

**Sequencing (value → risk):**
1. **`HomeLayoutStore` = explicit, behavior-preserving migration** of `HomeLibraryVisibility`
   (default-visible), with tests. *Foundation; also unblocks §8.*
2. **Theme step 0** (no deps — existing `ThemeSettingsStore`).
3. **First-run scaffolding** — fact-derived `FirstRunCoordinator` + welcome, wrapping the
   existing `SessionState` (don't rewrite it).
4. **Per-server reveal, libraries-only**, 1-tap, full-screen + later-add banner — one reusable
   component shared with `ServersAndLibrariesDetailView`.
5. **Profiles** — single binary (or multi-user detection prompt) + per-profile seed-from-default.
6. **Extend the reveal to playlists/collections + cross-server dedup** — gated on §8's
   `CuratedRowsProviding`.

### 9.6 Open questions for Brandon (this section)

1. **The core call:** opt-out **reveal** (everything on, trim later — fastest, my rec) vs
   **smart adaptive** (N=1 pre-selected, N>1 opt-in) vs **strict opt-in** (curate from empty)?
   My rec is *reveal + N>1 restraint*.
2. **Profiles prompt:** **auto-detect** a multi-user Plex Home and offer profiles only then (O1,
   lightest) — or always ask the **"Just me / Multiple people"** binary on first run (O2/O3, more
   discoverable)?
3. **Theme step:** keep a one-screen theme picker at step 0, or cut it from onboarding and just
   nudge in Settings?

> **Brandon's decisions (2026-06-25):** (2) **always ask** the "Just me / Multiple people"
> binary on first run. (3) **keep** the one-screen minimal theme picker (live re-themeable
> mock-scene preview noted as a clean v2). (1) deferred — superseded by the §10 navigation
> question below, which reframes where libraries live (so the reveal/opt-in choice now applies
> to Home highlight rows, not to a library dump).

---

## 10. Navigation & sub-navigation architecture

*Synthesized from four fresh blind branches (Opus 4.8 high, GPT-5.3-Codex xhigh, Gemini 3.1
Pro high, Sonnet 4.6 max), each answering an identical unbiased brief in isolation. Brandon's
prompt: keep core nav SIMPLE, define sub-navigation, ADAPT to 1-vs-N video AND music libraries
without duplicating functionality, and resolve whether navigation "pinning" (Plex's
customize-navigation) should exist at all — or whether Home is the single adaptable page.*

### 10.1 The grounding insight: Music already solved this once

Plozz's Music tab is the existing proof-of-concept every branch built on: it appears **only**
when `MusicAvailabilityModel.hasMusic` is true and **collapses N music libraries (across all
servers) into one adaptive tab**, leaving video-only users "byte-for-byte unchanged." The whole
navigation answer is a generalization of this one pattern: *content drives the nav; the user
does not assemble it.*

### 10.2 Unanimous convergence (all four branches)

These were not in the brief — all four arrived independently:

1. **REJECT Plex-style navigation pinning.** Pinning is a workaround for a mis-shaped nav and a
   burden pushed onto the user; it bloats the tvOS TabView and fights the fast brand. Fix the
   nav shape instead. (Answers Brandon's core "should we pin at all?" → **no.**)
2. **Evict the library rail from Home.** Home stops being the library surface and becomes a pure
   **highlight reel** (Continue Watching / Watchlist / Recently Added / featured). This is the
   real resolution of "maybe pinning lives within Home": there is nothing to pin because
   libraries no longer live on Home — so Home can't get cluttered. Keeping *both* a library rail
   on Home *and* a browse surface would be the duplication Brandon explicitly forbade.
3. **The app ADAPTS automatically; onboarding asks nothing about navigation.** Destinations
   appear/disappear from imported content exactly like the Music tab does today.
4. **Server is never a navigation axis.** Same library TYPE across servers (Movies on Plex +
   Jellyfin) collapses to ONE destination via `AggregatedLibrary` / `AggregatedLibraryProvider`.
   The only "which library / which server" affordance is an in-context **filter**, never a tab,
   page, or pin.
5. **One paradigm for video and music** — whatever adaptive sub-nav video uses, music reuses,
   so there aren't two different mental models.
6. **Progressive disclosure: hide chrome when redundant at N=1.** A single library deep-links
   straight to its grid (no hub, no picker); richer setups reveal more sub-nav. Degenerate cases
   never get a redundant hub; rich cases never become row-soup or a server tree.

### 10.3 The one real fork: where do content TYPES live?

Everything above is agreed. The branches split on the *shape* of browse:

| Branch | Top-level nav | Where content types live | N=1 / N rule |
|---|---|---|---|
| **r1 Opus 4.8** | Home · Search · Settings **+ auto per-TYPE "lens" tabs** (`Movies`, `Shows`, `Music`) | **Separate tab per canonical type** (capped to Movies/Shows/Music/Other), generalizing the Music tab to all types | tabs adapt to # of **types**; library chips inside a lens adapt to # of **libraries** |
| **r3 Gemini** | Home · **Browse** · [Music] · Search | **One unified Browse tab**; types are a **left rail** inside it | Browse deep-links to grid at 1; left rail of types at N |
| **r4 Sonnet 4.6** | Home · **Browse** · [Music] · Settings | **One unified Browse tab**; types are a **top segmented strip** inside it | Browse conditional on any video lib (parallel to `hasMusic`); type strip hidden at 1 type; music gets `All\|LibA\|LibB` filter at N |
| **r2 Codex** | Home · Search · [Music] · Settings | **No new tab** — browse reached via **jump actions from Home**; adaptive sub-nav by count | 1→deep-link grid; 2–5→inline scope chips; >5→`All` + filter/search panel |

So the spectrum on **"how do you reach a Movies grid"** is:

- **r1:** a dedicated **Movies tab** (most prominent, most tabs — but capped & content-driven).
- **r3/r4:** one **Browse tab**, type chosen inside (one fixed extra tab, types are sub-nav).
- **r2:** **no browse tab at all** — you jump in from Home (fewest tabs, browse is a mode).

### 10.4 Orchestrator recommendation

**Adopt the r3/r4 "single Browse tab" core, with Sonnet's `hasVideo`-conditional appearance and
the unanimous Home-cleanup.** Concretely:

- **Core nav (fixed, ≤4 tabs):** `Home · Browse* · Music* · Settings` — where `Browse` appears
  when any video library exists and `Music` appears when any music library exists (both mirror
  today's `hasMusic` precedent). Search folds into Browse/Home as a function rather than eating a
  permanent tab slot, or stays as a 5th only if Brandon prefers it surfaced. Tab count never
  varies with *library* count — only with whether video/music exist at all.
- **Inside Browse — adaptive sub-nav, one component:** an aggregated **type strip/rail**
  (`Movies | TV | Kids | 4K…`) that is **hidden when only one type exists** (deep-link straight to
  the grid). Use Codex's count thresholds for the *library* dimension within a type (1→direct,
  2–5→inline chips, >5→`All` + filter panel). Stack depth: Browse → Grid → Detail. Same
  `LibraryBrowseView` + `AggregatedLibraryProvider` that already exist.
- **Music** reuses the identical filter paradigm (`All | LibA | LibB` when N>1, merged at 1).
- **Home** becomes the highlight reel only (CW / Watchlist / Recent / §8 featured rows); the
  library rail is removed.

**Why this over r1's per-type tabs:** r1's lens-tabs are elegant and the purest generalization of
Music, but variable *type* tabs (a Movies tab today, a Movies+Shows+Anime set tomorrow as content
changes) trades muscle-memory stability for prominence — and on tvOS a fixed, predictable top bar
is worth more than surfacing each type one level higher. r3/r4's single Browse keeps the bar
stable while still letting content fully drive what's *inside* it. **Why not r2's no-browse-tab:**
discoverability — a first-class Browse destination is the obvious home for catalog exploration once
the library rail leaves Home; reaching browse only via Home jump-actions hides it.

**This also reframes the §9.6 question 1** (reveal vs opt-in): with libraries living in Browse
(always all present, server-merged) rather than as Home rows, the onboarding "curation" choice
collapses to *which highlight rows seed Home* — a much smaller, lower-stakes decision that the
opt-out **reveal** model handles cleanly.

### 10.5 Migration & sequencing (converged value→risk order)

1. **Add the Browse tab** (additive, conditional on `hasVideo`, zero risk) with the adaptive
   type strip + `AggregatedLibraryProvider` grids.
2. **Add the music library filter** at N>1 (additive, very low risk).
3. **Remove the library rail from Home** → highlight reel (HIGH value, medium risk: users
   retrain; mitigate with a one-time contextual hint).
4. **Migrate `HomeLibraryVisibility`** (opt-out) → Browse type/library visibility + Home
   highlight-row config (low-risk cleanup; preserve existing hidden keys).
5. **Cross-type / cross-server merge polish** and per-type merge toggle in per-server setup.

### 10.6 Open questions for Brandon (this section)

1. **The core fork:** single **Browse tab** with types inside (r3/r4 — my rec) vs **per-type
   "lens" tabs** (r1, Music generalized to Movies/Shows) vs **no browse tab, jump from Home**
   (r2)?
2. **Search:** keep Search as its own permanent tab, or fold it into Browse/Home to keep the bar
   at ≤4 fixed tabs?
3. **Home cleanup:** confirm you're OK **removing the library rail from Home** (the move all four
   branches depend on) — Home becomes CW/Watchlist/Recent/featured only.

> **Superseded by §10.7.** Question 3 here is REVISED by the focused follow-up below: don't remove
> the rail outright — replace the library *content* rail with a small library *access* shelf.

### 10.7 Refinement — user-curated libraries ARE the navigation primitive

*Brandon pushed back on §10.3/§10.4's instinct to group browse by canonical TYPE: "a library is
the user's own curation unit — my sister has a dedicated **Anime** library; people make
**Animated Movies**, **Home Media**, **4K**, **Kids** — and removing the Anime rail can't mean she
has to search for anime." A focused blind pass (Opus 4.8 high, GPT-5.3-Codex xhigh, Gemini 3.1 Pro
high) pressure-tested exactly this. All three converged hard; the result amends §10.*

**Decisive finding (r1 Opus):** §10.3's own illustration — a type strip reading
`Movies | TV | Kids | 4K` — already leaks: **"Kids" and "4K" are custom library NAMES, not canonical
types.** The type abstraction breaks the instant you draw a real user's libraries. So the fix is to
**delete the canonical-type layer, not patch it.**

**Unanimous across all three branches:**
1. **The library — with its human NAME — is the navigation primitive.** Browse lists the user's
   named, server-merged libraries directly (Anime, Animated Movies, Home Media, 4K…). There is **no
   Movies/TV grouping layer** above them.
2. **Merge by NAME, never by type.** Merge key = `(normalize(displayName), kind/mediaDomain)` with
   normalization limited to **case + whitespace only** — so "Anime" on Plex + "Anime" on Jellyfin
   become one destination, while "Movies" and "Animated Movies" and "4K Movies" stay distinct.
   Never strip qualifiers like Animated/4K/Kids; never merge by canonical type. Provide a per-library
   **"keep separate"** override for rare false merges. Server is still never an axis. (Code note: this
   name-merge is a **dormant** capability today — `MediaLibrary.additionalSourceAccountIDs`,
   `AggregatedLibraryProvider`, `resolveLibraryBrowse` exist but the aggregator never populates them;
   wiring it is scoped, not a rewrite.)
3. **Genres are in-grid FILTERS, not destinations.** "Action films" = a filter/sort inside a grid,
   optionally *promotable* to a saved "smart shortcut / lens" — never a top-level Browse entry.
4. **"Trending" / Continue Watching / Recently Added are Home highlight rows** (synthesized),
   never Browse entries.
5. **Preserve a FAST PATH to a favorite library** — the controlled survivor of "pinning." This is
   the explicit fix for the sister-regression: §10 said remove the Home library rail; this refinement
   says remove the library **content rail** but **keep a small library ACCESS affordance** so Anime
   stays one tap from Home.
6. **Adapt 1→N with the same components:** N=1 → Browse deep-links straight into the single grid
   (no index, no shelf); 2–3 → named cards; 7+/across servers → name-merge first, then an
   alphabetized named grid + jump-search. Music reuses the identical named-library paradigm.
7. **Onboarding asks nothing about this** — auto-adapt; favorites are learned or set later in
   Settings/long-press.

**The one divergence — how the fast path works:**

| Branch | Fast-path mechanism |
|---|---|
| **r1 Opus** | A capped **auto-ranked MRU shortcut shelf** on Home (~5 named tiles; Anime floats to front by usage) + optional long-press "keep at front." Ship the shelf **atomically with** rail removal. |
| **r2 Codex** | One explicit **Primary library** (long-press to set) → a single Home hero shortcut + Browse focuses it; bounded shortcut layer (Primary + ~2 recents). |
| **r3 Gemini** | **State restoration** — Browse reopens your last-used library (Anime already selected) — + optional library-seeded Home *content* row. |

**Orchestrator recommendation:** Adopt the unanimous core (libraries are named first-class
destinations; delete the type layer; name+kind merge with conservative normalization; genres =
filters; trending = Home rows). For the fast path, combine **r1's auto-MRU shortcut shelf as the
zero-config default** (it makes Anime one tap away with no setup — directly answers the sister case)
**with r2's optional explicit pin** as the power-user override, and adopt **r3's Browse
state-restoration** for free (it's additive and costs nothing). Crucially: **ship the access shelf
in the same change that removes the content rail** — never remove the rail first, or you reintroduce
the regression. This makes §10.4's Browse a **named-library index/grid**, not a type strip.

**Value→risk sequence (converged):** (1) Browse named-library grid + deep-link at N=1 [additive];
(2) wire the dormant name+kind merge; (3) Home highlights + capped access shelf — **shipped
atomically with** library-content-rail removal; (4) in-grid genre filters; (5) Settings overrides
(hide / keep-separate / pin); (6) promotable smart-shortcuts/lenses last. **Top risks:**
over-normalization fusing distinct libraries (mitigate: case+whitespace only + override); large-N
discoverability/peek fan-out (lazy-load + jump-search); shelf cold-start (seed by size/recency);
**never remove the content rail before the access shelf ships.**

### 10.8 Open questions for Brandon (refined)

1. **Confirm the primitive:** libraries are **named first-class destinations** with **no
   canonical-type grouping** layer (all three branches + the leak finding say yes)?
2. **Fast path:** auto-**MRU shortcut shelf** on Home (zero-config, my rec) + optional explicit
   **pin** — vs an explicit **Primary-only** model — vs **last-used reopen** only?
3. **Home:** OK to remove library **content** rails but **keep a capped library access shelf**
   (the revised answer to §10.6 Q3 — this is what keeps your sister's Anime one tap away)?

---

*Full individual proposals (with code citations, trade-off tables, and per-branch
implementation sketches) are preserved in each research branch's `plan.md`. Branches:
`thatcube-strategy-research-opus48`, `thatcube-strategy-r2-codex-5-3-xhigh`,
`thatcube-didactic-dollop`, `thatcube-strategy-r4-opus-xhigh`,
`thatcube-strategy-research-r5`; §8 addendum: `thatcube-home-rows-strategy-research`,
`thatcube-srvrows-r2-codex`, `thatcube-scaling-enigma`; §9 addendum:
`thatcube-onboarding-research-opus48`, `thatcube-onboarding-r2-codex`,
`thatcube-jubilant-couscous`; §10 navigation: `thatcube-nav-arch-r1-opus48`,
`thatcube-nav-arch-r2-codex`, `thatcube-animated-pancake`, `thatcube-nav-arch-r4-sonnet46`;
§10.7 curated-libraries refinement: `thatcube-curated-libraries-research`,
`thatcube-curated-libraries-pressure-test`, `thatcube-special-couscous`.*
