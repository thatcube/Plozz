# Localization

Plozz ships English today and is being localized incrementally. This document is
the contract: how strings get from Swift source into a translator's hands and back
into the app, and the handful of rules that keep that pipeline working.

## The one thing to understand first

Almost all of Plozz's UI lives in **Swift package targets** (`AppShell`,
`AppShelliOS`, `FeatureSettings`, …); the `App/` targets are thin shells with
essentially no copy of their own. That matters because of an asymmetry:

- **At runtime**, a SwiftUI/Foundation localization lookup compiled into a package
  target resolves against **`Bundle.main`** — the *app's* bundle, not the module's.
- **At build time**, the compiler's string *extraction* is **per-module**: it writes
  a `.stringsdata` file per source file into each target's build directory.

So the app reads from one place, but the toolchain writes to ~46. Plozz resolves
this by keeping **one app-owned catalog**, `App/Resources/Localizable.xcstrings`,
referenced by both the tvOS and iOS app targets, and bridging the gap with
`tools/l10n-sync.py`.

Consequences worth internalising:

- A string written in `FeatureSettings` is translated in the **app** catalog. Do not
  add per-module `.xcstrings` files.
- Both app targets reference the **same** catalog file, so tvOS and iOS cannot drift.
- The **Top Shelf extension is a separate bundle and process.** Its strings do *not*
  belong in the app catalog and are excluded by the sync tool.

## Adding or changing a string

1. Write the string in Swift (see the rules below).
2. Run `tools/l10n-sync.py`.
3. Commit the Swift change **and** the updated catalog together.

That is the whole loop. The sync tool builds both platforms with extraction
enabled, collects the `.stringsdata`, and hands them to Apple's
`xcrun xcstringstool sync`, which owns the catalog itself.

```sh
tools/l10n-sync.py                 # build both platforms, sync the catalog
tools/l10n-sync.py --check         # fail if the catalog is out of date (CI)
tools/l10n-sync.py --no-build      # reuse the last extraction build (fast iteration)
tools/l10n-sync.py --platform tvos # faster partial run; never prunes (see below)
```

### Why a dedicated build

`SWIFT_EMIT_LOC_STRINGS=YES` is what makes the compiler emit `.stringsdata`. Two
non-obvious facts, both established by measurement rather than documentation:

1. Setting it in `project.yml` extracts **nothing** from SwiftPM targets. It only
   takes effect when passed on the `xcodebuild` command line.
2. `defaultLocalization: "en"` in `Package.swift` is **also** required. Without it
   the export silently produces an empty catalog even while `.stringsdata` files
   are being written.

Neither failure produces an error message — you just get an empty catalog. Both are
handled inside `tools/l10n-sync.py`, which is why extraction has exactly one entry
point.

**Do not** thread `SWIFT_EMIT_LOC_STRINGS` through `deploy-tv.sh`, `deploy-ios.sh`,
`run-tests.sh`, fastlane or CI builds. Shipping builds need only the checked-in
catalog; extraction metadata is pure build cost there.

### Stale strings and platform coverage

A tvOS build cannot see iOS-only copy, and vice versa. If stale marking ran from a
single-platform build it would prune the other platform's strings. So the tool
builds **both** platforms by default and only allows stale marking when it has the
full union; `--platform` forces stale marking off.

## Writing strings

### Use natural-language keys by default

```swift
Text("Search")                                    // key IS the English text
var title: LocalizedStringResource { "Movies" }
```

This keeps automatic extraction working and call sites readable.

### Use a semantic key when the string needs one

Reach for a semantic key when the same English text means different things in
different places, when the identifier is persisted or crosses a process boundary,
or when the copy churns enough that a stable key is worth it. Always supply an
explicit `defaultValue` and `comment`:

```swift
LocalizedStringResource(
    "search.section.movies",
    defaultValue: "Movies",
    comment: "Header for the search-results section listing movies."
)
```

`comment:` takes a `StaticString` — it must be a single literal, not a
concatenation.

### Never let identity depend on localized text

This is the rule most likely to cause a subtle bug. If a view's `Identifiable` id
(or `Hashable` conformance) derives from displayed text, switching language changes
SwiftUI identity, which tears down and rebuilds the view — dropping tvOS focus
mid-browse. `SearchSection` shows the shape to copy: a `Kind` enum is the identity,
and `title` is a computed `LocalizedStringResource` derived from it.

### Distinguish app copy from content

Media titles, filenames, usernames, server names, URLs and codec names are
**content**, not copy. They must never be translated:

```swift
Text(verbatim: item.title)   // provider content
Text("Continue Watching")    // app copy
```

Content stays `String`. App copy becomes `LocalizedStringResource`.

### Brand names are not copy

Provider and format names must never be translated — a translator seeing "Plex" in
a catalog has no way to know that, and some will translate it:

```swift
Text(verbatim: "Jellyfin")              // brand
.navigationTitle(Text(verbatim: "Plex"))
```

The guard enforces this against the `neverTranslate` list in
`tools/l10n-guard.json`.

### Never build a sentence with `+`

```swift
Text("Connect a server. " + "Each profile can request separately.")   // WRONG
```

This is not merely bad for word order: `"a" + "b"` is an *expression*, not a
literal, so the compiler's extractor **skips it entirely** — the string never
enters the catalog and can never be translated. Six real strings were lost this
way before the guard existed. Wrap long copy with a multi-line literal instead,
which stays a single literal:

```swift
Text(
    """
    Connect a server. \
    Each profile can request separately.
    """
)
```

### `Text(someString)` renders verbatim — this is the classic trap

A `String` reaching `Text` is **not** localized. Copy modelled as `String` in a
model or a component parameter is invisible both to the catalog and to the
extractor, and silently stays English. If a property carries fixed app copy, its
type should be `LocalizedStringResource`.

Before converting a property, check the enclosing type's conformances:
`LocalizedStringResource` is `Equatable`, `Codable` and `Sendable`, but **not
`Hashable`** — converting a stored property on a `Hashable` type breaks the
synthesized conformance.

Also avoid eager resolution (`Text(String(localized: …))`). It freezes the value
and defeats live language switching.

## Translating

Translators edit `App/Resources/Localizable.xcstrings` directly — in Xcode's String
Catalog editor, or as JSON. Every entry carries a `comment`; write one for every new
string, because it is the only context a translator gets.

**Do not use `-importLocalizations` with module-generated XLIFF.** Its
`<file original="Sources/FeatureSettings/…">` entries point at module resources and
the importer will not retarget them to the app catalog. If XLIFF is needed: sync
first, export only the app-owned catalog, then import that export unchanged.

## Choosing a language in the app

Settings › Appearance › Language (both shells). The option list is built from
`AppLanguage.available()`, which reads `Bundle.main.localizations` — so a newly
translated language appears on its own, and a language can never be offered that
has no strings behind it.

It is applied by `CoreUI.AppLanguageScope`, which wraps each app's root view and
injects `\.locale`. That re-renders live, with no relaunch — unlike changing the
system language, which kills and restarts the process.

The setting is stored **per profile** (`AppLanguageSettingsStore`, scoped exactly
like every other settings store), so one household member can read Plozz in
Spanish while another keeps English on the same Apple TV.

### What it deliberately does not change

| Not affected | Why |
| --- | --- |
| Media titles, overviews, genres | They come from Jellyfin/Plex in whatever language that server is configured with |
| Audio / subtitle track languages | A German UI does not imply German audio — they are separate settings on purpose |
| Dates, numbers, sort order | Those follow the device REGION, which the override preserves |
| AVKit player chrome, permission prompts | System-drawn; they follow the device language and no in-app setting can change that |
| Top Shelf | A separate bundle **and** a separate process |

`.environment(\.locale,)` also does **not** change `Locale.current`. Any non-view
code that formats, compares or sorts text must be handed a locale explicitly
rather than reading the process-wide one.

## Verifying

```sh
tools/l10n-guard.sh                         # catch localization regressions
tools/run-tests.sh FeatureSearchCoreTests   # localization invariants live here
tools/deploy-tv.sh --build-only             # tvOS compiles
tools/l10n-sync.py --check                  # catalog matches the source
```

To check a language on a simulator, launch with an explicit language argument:

```sh
xcrun simctl launch <sim-id> com.thatcube.Plozz -AppleLanguages "(es)"
```

## The guard (`tools/l10n-guard.sh`)

Runs in CI. It parses the source with SwiftSyntax — shipped inside the toolchain,
so it needs no package dependency — and checks five things:

| Rule | What it catches |
| --- | --- |
| `eager-localization` | `Text(String(localized:))`, which freezes the value and defeats live locale switching |
| `key-from-variable` | `LocalizedStringKey(someString)` — a runtime string can't be a catalog key |
| `concatenated-copy` | `Text("a " + "b")` — **the extractor skips this entirely**, so the string never reaches the catalog and can never be translated |
| `brand-not-verbatim` | "Jellyfin"/"Plex"/… entering the catalog as translatable |
| `copy-typed-as-string` | a migrated file reverting a copy property to `String` |
| `copy-returned-as-string` | a function or computed property **returning** prose as `String`; catches what the rule above misses, because that one only looks at copy-shaped *names* |
| `hand-rolled-plural` | `"\(n) \(n == 1 ? "item" : "items")"` — a counted phrase built from fragments |

Rules 1–4 and `hand-rolled-plural` run repo-wide. The two `copy-…-as-string`
rules run **only** on `auditedPaths` in `tools/l10n-guard.json` — add a path
there as part of migrating that slice. That is what tightens the net.

`hand-rolled-plural` deliberately does **not** flag a bare ternary between two
literals that never shows the number (`count == 1 ? "Server" : "Servers"`).
`xcstringstool` refuses a plural variation whose values don't reference the
count, and tells you to use two top-level strings — so that shape is the
platform's own answer, not a workaround.

### Why these rules and not others

Every rule is **syntactically decidable**. A syntax tree cannot tell
`Text(section.title)` (a `LocalizedStringResource`, fine) from `Text(item.title)`
(media content, must be verbatim) — they are the same shape. Any rule needing that
distinction would be guessing, so it isn't a rule. Type-level checking is the
compiler's job, not this tool's.

That also rules out the tempting "count bare string literals and ratchet down"
design: SF Symbol names, log messages, URLs, codec names and test fixtures are all
bare literals and none are copy, while the actual failure mode — copy modelled as
a runtime `String` — isn't a literal at all.

### No baseline

Any finding fails. There was a per-rule baseline while the migration was in
flight — it seeded from the repo's existing debt and only allowed counts to fall.
That debt reached zero, so the file was deleted rather than kept: an empty
baseline behaves exactly like no baseline, and keeping it invites someone to
re-seed it and quietly accept new debt.

### Marking content in an audited file

A property holding real content (a media title, filename, username) inside an
audited file is exempted explicitly:

```swift
let title: String   // l10n:content — provider-supplied media title
```

Deliberately greppable: exempting content should be a visible decision.

### Catalog validation

`l10n-sync.py` also validates the artifact translators actually receive, which
is a different question from "does the code compile". It fails on:

- a brand from `neverTranslate` sitting in the catalog as translatable;
- a key with no words in it (`""`, `"%@ · %@"`) — usually a sign that content
  and copy were interpolated into one resource;
- a key that counts something but carries no plural variations, or a variation
  whose placeholders don't match its key (a dropped specifier is a crash);
- an `InfoPlist.xcstrings` that has drifted from the `Info.plist` it mirrors.

```sh
python3 tools/l10n-sync.py                  # extract + sync (run this when adding strings)
python3 tools/l10n-sync.py --validate-only  # validate the committed catalog; no build needed
python3 tools/l10n-sync.py --check          # the above, plus proves the catalog is in sync
```

> **CI runs the guard and `--validate-only`.** It does not run the full
> `--check`: proving the catalog is in sync means rebuilding **both** platforms
> with extraction enabled, which roughly doubles CI time. Freshness is a local
> obligation — run `tools/l10n-sync.py` and commit the catalog whenever you add
> or change a string.

### Pseudolocalization

Before a language ships, run the UI under Apple's pseudolanguages. They need no
translations and no `.lproj` — the system generates them from the base language,
so this works today, with an untranslated catalog.

```sh
tools/deploy-tv.sh --branded --pseudo       # en-XA: accented and lengthened
tools/deploy-tv.sh --branded --pseudo-rtl   # ar-XB: the above, plus mirrored
```

On iPhone/iPad `tools/deploy-ios.sh` installs but doesn't launch, so pass the
arguments to the launch yourself:

```sh
xcrun devicectl device process launch --device <udid> <bundle-id> \
  -- -AppleLanguages "(en-XA)" -AppleLocale "en-XA"
```

They are launch arguments, so the device's own language is untouched and the
next ordinary launch is normal.

What to look for:

- **Text that is still plain ASCII never reached the catalog.** This is the one
  check that finds copy the guard cannot: a `String` built at runtime, a string
  in a module nobody audited, text baked into an image.
- **Text that clips or truncates.** German and Finnish run 30–40% longer than
  English; `en-XA` approximates that. tvOS focus rows and the tab bar are the
  usual casualties.
- **Under `ar-XB`, anything that doesn't mirror.** That is a hard-coded
  `.leading`/`.trailing` assumption, or a chevron pointing the wrong way.

### Plurals

Anything that counts something needs plural variations in the catalog, because
English's two forms are not enough for Polish (4) or Arabic (6), and a
translator handed a flat string has nowhere to put the others.

- **The phrase shows the number** → one resource with the count interpolated
  (`"\(n) episodes"`), plus plural variations in the catalog. If the string has
  other arguments too, only the counted fragment becomes a substitution.
- **The phrase does not show the number** ("Server" / "Servers") → two separate
  top-level strings chosen in code. `xcstringstool` rejects the alternative.

## Do not

- Do not hand-write or hand-merge `.xcstrings` JSON. `xcstringstool` owns the
  catalog: stale marking, plural/device variations, translation states and comments.
  A bespoke merger silently destroys them.
- Do not add per-module `.xcstrings` files.
- Do not put Top Shelf strings in the app catalog.
- Do not enable extraction on normal developer, test, or archive builds.
- Do not use localized text as `Identifiable`/`Hashable` identity.
- Do not persist a `LocalizedStringResource` just because it is `Codable`.
- Do not bulk-convert every `String` property; most are content, not copy.
