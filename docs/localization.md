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

## Verifying

```sh
tools/run-tests.sh FeatureSearchCoreTests   # localization invariants live here
tools/deploy-tv.sh --build-only             # tvOS compiles
tools/l10n-sync.py --check                  # catalog matches the source
```

To check a language on a simulator, launch with an explicit language argument:

```sh
xcrun simctl launch <sim-id> com.thatcube.Plozz -AppleLanguages "(es)"
```

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
