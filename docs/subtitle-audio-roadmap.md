# Plozz Subtitle & Audio — Extended Roadmap

**Status:** living roadmap. Captures everything shipped, decided, and still
planned for the subtitle/audio overhaul. The detailed design rationale lives in
the v2 architecture design (session artifact `subtitle-architecture-v2.md`,
phases P1–P7); this doc is the prioritized, current-reality plan that sits on top
of it.

**Next priority (agreed):** after the Settings split-view redesign, the
**Sourcing** track (search + auto-download + cross-server cue cache, Plex AND
Jellyfin) comes first.

---

## ✅ Shipped to `main`

The foundation of the "Plozz owns subtitle rendering" architecture is in:

- **Owned SDR renderer** — `SubtitleOverlayView` (Sources/FeaturePlayback): one
  Plozz-owned SwiftUI/Core-Animation drawing surface, pure data-in
  (primary/secondary cues + style + isHDR + videoRect). No engine draws subs in
  the end state.
- **Unified cue model** (Sources/CoreModels): `SubtitleCue` / `SubtitleText` /
  `SubtitleCueLayout` / `SubtitleCueStream` / `SubtitleCueStore` /
  `SubtitleCueTimeline`, plus `SubtitleCueParser` (SRT/VTT/ASS-SSA).
- **Text sidecars routed through the overlay** on **both** the native (AVPlayer)
  engine and Plozzigen — manual menu selection fetches `deliveryURL`, parses
  off-main, and draws our own cues (suppressing AVPlayer's legible draw).
- **Per-content-type subtitle policy** — Off / On / Forced-only, with optional
  per-type overrides (movie / tv / anime) + Settings UI.
- **Per-content-type audio language** — Original / Device / specific language,
  with optional per-type overrides (movie / tv / anime) + Settings UI
  (`AudioPolicy` mirrors `SubtitlePolicy`).
- **Per-series cross-server memory** — remembered audio + subtitle choices that
  follow a show across Plex ↔ Jellyfin, keyed by external IDs
  (tvdb/tmdb/imdb/anilist/mal/anidb).
- **Robustness** — encoding-tolerant sidecars, ASS/SSA parsing, native no-URL
  fallback, and an audio indicator that reflects the engine's *actual* active
  track.
- **Settings section-header restyle** — compact uppercase/dimmed headers so a
  section header is no longer indistinguishable from the rows beneath it.

---

## 🔜 Remaining work (grouped & prioritized)

### B. Sourcing — **NEXT PRIORITY**

A self-contained phase: get more subtitles, keylessly, on both providers, and
make a downloaded subtitle behave well across servers.

- **Manual keyless search + download**, in-player. Provider-proxied so there is
  **no user-supplied API key** — the Jellyfin/Plex server already has the
  subtitle agent/account; the client calls the server's search + download
  endpoints. **Both Plex and Jellyfin** (Jellyfin path largely exists; add Plex
  parity).
- **Automatic subtitle download** when a policy match is missing. The
  `autoDownloadIfMissing` flag already exists on `SubtitlePolicy`; wire it to a
  pre-fetch at item-detail / on play.
- **🔑 Downloaded subs × multi-server (design decision).** A downloaded subtitle
  must not be trapped on one server. **Proposed approach:** store the downloaded
  cues **client-side, keyed by the cross-server episode identity** (the same
  external-ID keys that already power per-series memory), so the subtitle
  **follows the episode across Plex ↔ Jellyfin**. Optionally also offer "save to
  server" so other clients benefit. This reuses the cross-server identity layer
  already built for per-series memory. *Needs a short storage design before
  build.*

### A. Rendering completeness

The capabilities that are the whole reason we own the renderer.

- **HDR luminance clamp** in the overlay — render subs in SDR so the system maps
  SDR white to ~100–203 nits reference white; expose a nits **ceiling** knob.
- **Bitmap subs** (PGS / VOBSUB / DVD) via Plozzigen `.image` cues composited
  through the overlay (with luminance clamp). Routing, not drawing, on native.
- **Fully wire `PlozzigenVideoEngine.subtitleCues`** — today only manually
  selected *text sidecars* route through the overlay; the engine's own cue
  stream (text + bitmap) is not yet wired.
- **Appearance panel with live preview** — size, position, color, background,
  shadow, border, opacity (extends today's `CaptionSettings`, keep Codable
  back-compat).
- **Manual offset slider** (timestamp transform on cues we own) → later
  **auto-sync** (see G).

### C. Policy intelligence

- **Symmetric per-content-type subtitle *language*.** Today only the subtitle
  *mode* is per-content-type; audio is already per-type *language*. Bring
  subtitle language to parity (per-type preferred language).
- **Confirm forced-only as a profile-base default** (the "only forced subs for
  foreign scenes" use case) — currently a per-type mode; decide whether it's also
  a first-class base default.

### D. Correctness bug

- **Plex audio-language mislabel.** Live report: a Plex show shows
  "HR / 5.1 / Doc_Ramen" instead of English / Japanese / French. Needs a Plex
  `Stream` language-mapping audit (we are reading the wrong field / not mapping
  language codes).

### E. UI / UX

- **Expose ALL caption/appearance settings in the UI** *(required)* — every
  caption-style knob surfaced both in the **in-player hub** and the **Settings**
  page.
- **Settings split-view redesign** — Level-2 settings pages become a master/detail
  split (focusable list left, live-updating control pane center/right reusing
  existing controls). *Tracked separately; handed to a dedicated agent.*

### F. Cleanup

- **Retire mpv** (P5) — trailer-audio fix, then delete the mpv engine + build
  wiring.
- **Deferred review MEDIUM/LOWs** from the overnight run — forward-compat decode
  of unknown policy keys, store lock-race, guard `.other` overridability,
  override-language drift, hoist per-profile stores into AppState.

### G. Differentiators (future seam)

- **Dual subtitles** (e.g. English + Japanese) — secondary cue stream (the
  renderer already accepts primary + secondary).
- **Language-learning suite** — tap-to-define dictionary, furigana/romaji/pinyin,
  word-level karaoke highlight.
- **On-device generated subs** (whisper.cpp) — design the source seam now, build
  later.

---

## ❓ Open decisions

1. **Downloaded subs × multi-server** — confirm the client-side, cross-server-keyed
   cue-cache approach (above) and design its storage.
2. **Forced-only at profile base** — first-class base default, or per-type only?
3. **Plex search prerequisite** — OK to require the user's Plex server to have a
   subtitle agent (OpenSubtitles / Sub-Zero) configured, mirroring Jellyfin? (No
   client key either way.)
4. **Differentiator appetite** — prioritize the language-learning suite, or park
   it as a clearly-future seam?

---

## Reference

- Detailed design + phase definitions (P1–P7), HDR deep-dive, cue-source table,
  and the "own the renderer" rationale: `subtitle-architecture-v2.md`
  (session artifact).
- Cross-server identity + per-series memory keying: `SeriesTrackPreferenceKey`
  (Sources/CoreModels), `crossServerKeys(providerIDs:)`.
