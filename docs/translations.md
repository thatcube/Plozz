# Translating Plozz

How translations are sourced, reviewed and shipped. For the engineering rules —
what makes a string translatable in the first place — see
[`localization.md`](localization.md).

## Current production system

Translations are produced and reviewed by independent high-capability language
models, then treated as untrusted batch input. They never edit
`Localizable.xcstrings` directly:

1. A source packet contains every key, English value, translator comment, and
   Apple plural/substitution structure.
2. One translator agent owns one language file outside Git. Agents work in
   parallel without sharing the catalog.
3. A different model reviews every entry against the source and comments,
   fixes terminology/grammar/context, and adds the three system permission
   prompts.
4. `tools/l10n-import.py` requires exact key coverage, nonempty values,
   `needs_review` provenance, canonical BCP-47 tags, unchanged placeholder types,
   valid plural leaves, and all permission prompts. It merges into temporary
   catalogs first and makes Apple's `xcstringstool` compile all three.
5. Only the importer writes the repository catalogs.

`tools/l10n-source-snapshot.json` fingerprints the source text, translator
comment, English variation structure, and three permission prompts from the
last completed pass. That catches changed semantic-key values and permission
copy even when a non-English localization still exists under the same key.

This is deliberate. `Localizable.xcstrings` is one large JSON file; allowing
parallel agents or translator pull requests to edit it directly creates merge
conflicts and makes one malformed language capable of corrupting every other
language.

### Why model translation is acceptable here

Plozz accepts useful, complete model translations over an English-only app.
Perfect native review before first release is not the gate; users can report a
poor phrase and corrections are cheap.

That policy is viable because this catalog has unusually strong context:

- 960 keys say where the string appears and what every placeholder contains.
- Ambiguous English collisions have separate semantic keys: the switch state
  “Off” is not the subtitle picker's “Off”; the network-share noun “Share” is not
  the diagnostics action verb.
- Runtime content and product/codec brands are separated from copy.
- Counts use real Apple plural variations, including independent substitutions
  for strings with two counts.
- An independent reviewer uses a different model from the first translator.
- Structural gates reject output that would crash, drop a number, corrupt a
  placeholder, or make a language silently fall back to English.

Every model-generated unit remains `needs_review`. That is provenance, not a
release blocker. A later native-speaker correction changes the unit to
`translated`.

## Languages

Plozz ships 36 non-English languages:

- Arabic, Bulgarian, Catalan, Croatian, Czech, Danish, Dutch
- Finnish, French, German, Greek, Hebrew, Hindi, Hungarian
- Indonesian, Italian, Japanese, Korean, Malay, Norwegian Bokmål
- Polish, Brazilian Portuguese, Romanian, Russian
- Serbian (Latin), Slovak, Slovenian, Spanish, Swedish, Thai, Turkish
- Ukrainian, Vietnamese, Simplified Chinese, Traditional Chinese, Persian

This set deliberately covers hard engineering cases, not just reach. German
stresses long labels; Polish/Russian/Ukrainian/Czech/Slovak exercise multi-form
plurals; Slovenian exercises the dual; Arabic/Hebrew/Persian exercise
right-to-left layout and logical navigation symbols.

## Quality gate

A model-generated language can ship when:

1. It has all catalog keys and all three permission prompts.
2. A second model completed a full independent review.
3. The importer passes placeholder, plural, locale-tag, state, and key-set
   validation.
4. `xcstringstool` compiles the merged app and permission catalogs.
5. Both platform builds and the full test suite pass.
6. `AppLanguage.releaseReady` explicitly includes the tag.

`needs_review` remains visible in `--coverage`; it tells maintainers what still
lacks native review without hiding a usable language from users.

## Commands

```sh
# Rebuild disposable full-language artifacts from the committed catalogs. This
# makes incremental translation self-contained; no prior agent session is needed.
tools/l10n-export-artifacts.py /tmp/plozz-translations

# Build a full packet, or only keys missing/stale for a language after a merge
tools/l10n-export-source.py /tmp/source.json
tools/l10n-export-source.py /tmp/fr-delta.json --missing-for fr

# Validate isolated language files without changing the catalog
python3 tools/l10n-import.py <artifact-dir> \
  --languages de,fr,es \
  --allow-translated-state \
  --require-info-plist

# Merge only after every listed language passes
python3 tools/l10n-import.py <artifact-dir> \
  --languages de,fr,es \
  --allow-translated-state \
  --require-info-plist \
  --apply

# Only after reviewed import and every final gate succeeds
tools/l10n-export-source.py /tmp/final-delta.json \
  --missing-for nl \
  --update-snapshot

# Catalog and source-code gates
python3 tools/l10n-sync.py --coverage
python3 tools/l10n-sync.py --validate-only
tools/l10n-export-source.py /tmp/delta.json --missing-for nl --check-snapshot
tools/l10n-guard.sh
```

## Automatic pre-main pass

Localization runs as part of landing a feature, not on a timer. The committed
`.githooks/pre-push` gate activates only for a push targeting `main`; ordinary
feature-branch pushes stay fast. The repository uses `core.hooksPath=.githooks`.

When an agent is told to merge or push a feature to `main`, the merge-time rule
in the private Plozz agent instructions requires it to:

1. syncs the English source catalog and exports disposable artifacts from the
   committed catalogs;
2. exports the exact missing-or-source-changed delta, including permission
   prompts, using the committed source fingerprint snapshot;
3. has one high-capability model translate every delta entry into all 36
   languages and a different model review every result;
4. merges through `l10n-merge-delta.py` and imports only through
   `l10n-import.py`;
5. runs catalog/source guards, pipeline tests, platform builds, and the full test
   suite;
6. updates the source snapshot and fast-forwards `main` only when every gate
   passes and `main` has not moved.

The pre-push hook is the mechanical backstop. It blocks `main` when source
extraction is stale, any language lacks a key, a source fingerprint changed
without reviewed translations, or catalog/source validation fails. The agent
then completes the translation pass on the feature branch and retries the same
push. Nothing polls and no partially localized feature reaches `main`.

This is a safety net after feature work, not permission to put user-facing
`String` values back into models. The source guard still requires copy to use
the localization-safe APIs documented in `localization.md`.

Importer regression tests run in CI because Apple’s compiler does **not** reject
every unsafe plural shape. During review, `xcstringstool` accepted a plural
category that dropped its count and another that added a nonexistent runtime
argument; the importer now blocks both.

## Corrections

Native speakers do not need a translation platform account. A translation issue
should identify:

- language;
- screen;
- current wording;
- better wording and, when useful, why.

The correction can be made directly in Xcode's String Catalog editor or in the
catalog JSON, validated, and shipped. A future Crowdin/Weblate-style platform is
optional community infrastructure, not a dependency for language support.
