# Translating Plozz

How translations are sourced, reviewed and shipped. For the engineering rules —
what makes a string translatable in the first place — see
[`localization.md`](localization.md).

## Where we are

```sh
python3 tools/l10n-sync.py --coverage
```

Every string in the app is translatable, the catalog validates, plurals are
expressed in the catalog rather than in Swift, and 960 of 1587 keys carry a
translator comment. Spanish exists at ~6% as a test seed and is **not offered**
in the language picker.

## The platform: Crowdin

**Weblate cannot be used.** It has no support for Apple String Catalogs — only
the legacy `.strings`/`.stringsdict` pair. The request
([weblate#10848](https://github.com/WeblateOrg/weblate/issues/10848)) has been
open since January 2024 and is blocked on its upstream parser library
([translate#5190](https://github.com/translate/translate/issues/5190)). Using it
would mean abandoning String Catalogs, which is the format Apple's own tooling —
extraction, `xcstringstool`, plural variations, the Xcode editor — is built
around. Not worth it.

**Crowdin supports `.xcstrings`** as a multilingual file, including plural
variations, and its
[open-source programme](https://crowdin.com/pricing) is free but requires an
application. [LiveContainer](https://github.com/LiveContainer/LiveContainer) is a
comparable iOS app running exactly this setup, so the path is proven.

Apple offers nothing here. Xcode's XLIFF export is a one-translator-at-a-time
workflow; Xcode Cloud and App Store Connect don't touch in-app strings.

### Why a platform rather than pull requests

`Localizable.xcstrings` is one JSON file. Twenty translators sending pull
requests against one file means twenty conflicts. Crowdin holds the translations
itself and writes back a single commit on an `l10n_` branch as one pull request,
so translators never touch the repo.

The residual conflict — Crowdin's branch vs. `main` when both change the catalog
— is inherent to a single-file format, not a Crowdin flaw. Expect to resolve it
occasionally.

A `crowdin.yml` is committed at the repo root, configured for the three
catalogs and marked inactive. It is a decision written down, not a live
integration — nothing is uploaded until a project exists.

### Verify before committing to it

Three things are undocumented and must be checked on a throwaway project first.
Each has a cheap workaround, but finding out late is expensive:

1. **Locale flooding.** A 2024 report
   ([crowdin/github-action#245](https://github.com/crowdin/github-action/issues/245))
   had Crowdin writing back *every* Crowdin system locale into the catalog,
   producing `ITMS-90176: Unrecognized Locale` on App Store upload. Closed as
   "not planned". Check the exported file contains only our languages.
2. **`shouldTranslate: false`** — does Crowdin respect it, or expose those keys
   to translators anyway?
3. **Comments** — do our 960 comments actually reach the translator's editor as
   context? They are the main quality investment; if they don't survive the
   round trip, the platform choice changes.

Also confirm a Crowdin round trip leaves `xcstringstool sync` happy — key order
and `extractionState` are not documented as preserved.

## Which languages

Deliberately not "as many as possible". Each language is a permanent maintenance
commitment: every new string reopens every language, and a half-translated UI is
worse than an English one because it looks broken rather than untranslated.

Start with a small set, ship it properly, and add more only when there is a
translator who will stay. Reasonable first candidates, on Apple TV/iOS install
base and on Jellyfin/Plex self-hosting communities: German, French, Spanish,
Italian, Portuguese (Brazil), Dutch, Polish, Chinese (Simplified), Japanese.

Two worth taking early for engineering reasons rather than reach:

- **German** is the truncation stress test — routinely 30–40% longer than
  English. If the tvOS focus rows survive German they survive most things.
- **Polish or Russian** exercises the plural work: four forms, so any place we
  got plurals wrong shows up immediately.

Arabic or Hebrew would additionally prove the right-to-left layout, but that is a
larger UI commitment — run `tools/deploy-tv.sh --pseudo-rtl` first and see how
much breaks before promising it.

## Quality gate

A language ships when it is **complete and reviewed**, not when it exists.

`AppLanguage.releaseReady` is the switch: the picker offers exactly the tags
listed there, and a language absent from it is invisible no matter how much of it
is translated. This is deliberate — a bundled `.lproj` only means *some* strings
were translated. Spanish sat at 6% with its folder present; offering it would
have shown a mostly-English UI to someone who asked for Spanish.

To add a language:

1. Coverage is at or near 100% (`--coverage` counts only the `translated`
   state — `needs_review` deliberately does not count).
2. A native speaker has read it **in the app**, not in a spreadsheet. Most bad
   translations are individually correct and wrong in context.
3. It has been through a pseudolocalization pass (see `localization.md`) and the
   layout survives.
4. Add the tag to `releaseReady`, in the order it should appear.

### On machine translation

Fine as a **seed**, never as a ship. Machine output goes in as `needs_review` so
it doesn't count toward coverage and can't reach the picker on its own. It gives
a volunteer something to correct rather than a blank file, which is a much
easier ask.

What it cannot do is judge the things this catalog is full of: whether "Off"
means a switch or a subtitle track, whether "Share" is a verb or a noun, whether
"Original" is a video quality or a download size. That is exactly what the
translator comments are for, and exactly what an unreviewed machine pass gets
wrong confidently.

## Keeping it honest

- `python3 tools/l10n-sync.py --coverage` — per-language state, the input to the
  `releaseReady` decision.
- `python3 tools/l10n-sync.py --validate-only` — runs in CI. Catches brands that
  became translatable, keys with no words in them, counted strings missing plural
  variations, and permission prompts drifting from `Info.plist`.
- `tools/l10n-guard.sh` — runs in CI. Catches copy reverting to `String`, eager
  resolution, concatenated copy, hand-rolled plurals.

When adding a string, run `tools/l10n-sync.py` and commit the catalog. A string
that never reaches the catalog cannot be translated by anyone.
