#!/usr/bin/env python3
"""l10n-sync.py — keep `App/Resources/Localizable.xcstrings` in step with the code.

Plozz serves ALL user-facing copy from ONE app-owned String Catalog. That works
because SwiftUI/Foundation localization lookups compiled into a Swift PACKAGE
target resolve against `Bundle.main`, not the module's own bundle — measured, not
assumed (see docs/localization.md). But the Swift compiler's string EXTRACTION is
per-module: it writes a `.stringsdata` file per source file into each target's
build directory. So extraction and runtime disagree about where strings live, and
something has to bridge them. That is this script's only job.

WHAT THIS SCRIPT IS NOT
-----------------------
It does NOT merge, rewrite or generate `.xcstrings` JSON. Apple ships
`xcrun xcstringstool sync` for exactly that, and it owns semantics we must not
reimplement: stale-entry marking, plural/device variations, translation states,
translator comments, and whatever the catalog schema grows next. A hand-rolled
merger silently destroys those. This script only decides WHICH `.stringsdata`
files are ours and then shells out.

WHY A DEDICATED BUILD
---------------------
`SWIFT_EMIT_LOC_STRINGS=YES` is what makes the compiler emit `.stringsdata`.
Two things about it are non-obvious and cost real time to discover:

  1. Setting it in `project.yml` does NOT reach SwiftPM targets. It only works
     when passed on the `xcodebuild` command line.
  2. It is pure build cost for shipping builds, which need nothing but the
     checked-in catalog.

So it lives here and ONLY here. Do not thread it through deploy-tv.sh,
run-tests.sh, fastlane or CI builds.

STALE MARKING AND PLATFORM COVERAGE
-----------------------------------
A tvOS build cannot see AppShelliOS's iOS-only strings, and vice versa. Letting
`xcstringstool sync` mark strings stale from a single-platform build would prune
the other platform's copy. This script therefore builds BOTH platforms by default
and only allows stale marking when it has the full union. `--platform` narrows the
build for speed, and in that case stale marking is forced off.

USAGE
  tools/l10n-sync.py                # build both platforms, sync the catalog
  tools/l10n-sync.py --check        # fail if the catalog is out of date (CI)
  tools/l10n-sync.py --platform tvos    # faster partial run; never prunes
  tools/l10n-sync.py --no-build     # reuse the last extraction build
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "App/Resources/Localizable.xcstrings"
APP_LANGUAGE_SOURCE = REPO / "Sources/CoreModels/AppLanguage.swift"
PROJECT = REPO / "Plozz.xcodeproj"

# A dedicated DerivedData root. Kept separate from the normal build so a routine
# `deploy-tv.sh` can never leave half-populated extraction output behind, and so
# wiping it costs a localization rebuild rather than everyone's incremental state.
DERIVED = REPO / ".build/l10n-deriveddata"

# The architecture the extraction build pins (see build_for_extraction). The
# collector must read the SAME arch or it will mix in a stale snapshot.
ARCH = platform.machine()

PLATFORMS = {
    # Simulator destinations on purpose: extraction only needs the code to
    # COMPILE, and a device destination drags in provisioning. A per-branch app id
    # cannot auto-provision iCloud/Push/Associated Domains, so a device build here
    # would fail on signing long before it emitted a single string.
    "tvos": ("Plozz", "generic/platform=tvOS Simulator"),
    "ios": ("PlozziOS", "generic/platform=iOS Simulator"),
}

# `.stringsdata` we must never feed into the APP catalog.
#
#   TopShelf*      the Top Shelf extension is a separate bundle AND a separate
#                  process; its strings belong in its own catalog, not ours.
#   *Tests         test fixtures are not shipped copy.
#   AppShortcuts   `ExtractedAppShortcutsMetadata.stringsdata` is an App Intents
#                  byproduct emitted for every target even when the target has no
#                  intents (Plozz has none at all).
EXCLUDED_SOURCE_MARKERS = ("/Tests/", "/TopShelf/", "/Sources/TopShelfKit/")
EXCLUDED_FILE_MARKERS = ("ExtractedAppShortcutsMetadata",)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=REPO, text=True, **kwargs)


def build_for_extraction(platform_keys: list[str], quiet: bool) -> None:
    """Compile with extraction enabled so the compiler writes `.stringsdata`."""
    env = dict(os.environ)
    # The host injects `safe.bareRepository=explicit`, which makes SwiftPM's
    # package resolution fail with "cannot use bare repository". Overwrite rather
    # than default: the variable is usually already SET to the offending value, so
    # a setdefault would silently leave the build broken.
    env["GIT_CONFIG_PARAMETERS"] = "'safe.bareRepository=all'"

    for key in platform_keys:
        scheme, destination = PLATFORMS[key]
        print(f"▸ Extraction build: {scheme} ({destination})")
        cmd = [
            "xcodebuild",
            "-project", str(PROJECT),
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", destination,
            "-derivedDataPath", str(DERIVED),
            # Only reachable from the command line — see the module docstring.
            "SWIFT_EMIT_LOC_STRINGS=YES",
            # Extraction never installs or runs anything, so signing is pure cost
            # (and would fail outright for a per-branch app id).
            "CODE_SIGNING_ALLOWED=NO",
            # A *generic* simulator destination builds every simulator arch, but
            # some vendored xcframeworks (LibDovi) ship no x86_64 simulator slice,
            # so the link fails on a symbol hunt we do not care about. Extraction
            # only needs one arch to compile — use the host's.
            f"ARCHS={ARCH}",
            "ONLY_ACTIVE_ARCH=NO",
            "build",
        ]
        proc = subprocess.run(
            cmd, cwd=REPO, env=env, text=True,
            stdout=subprocess.PIPE if quiet else None,
            stderr=subprocess.STDOUT if quiet else None,
        )
        if proc.returncode != 0:
            if quiet and proc.stdout:
                # Only the decisive lines; a full xcodebuild log is unreadable.
                tail = [ln for ln in proc.stdout.splitlines() if "error:" in ln]
                print("\n".join(tail[-25:] or proc.stdout.splitlines()[-25:]),
                      file=sys.stderr)
            sys.exit(f"✗ Extraction build failed for {scheme}.")


def collect_stringsdata(arch: str) -> list[Path]:
    """Every `.stringsdata` that represents app copy we own.

    Three filters, each for a failure actually observed:

    * **Architecture.** DerivedData accumulates a directory per architecture and
      never prunes them. An earlier run that built a different arch leaves a full
      set of `.stringsdata` behind, and globbing everything mixes that stale
      snapshot into the current one — deleted strings come back from the dead.
      Since the build pins ARCHS, only that arch's output is current.
    * **Deleted sources.** A renamed or removed `.swift` file leaves its
      `.stringsdata` behind forever, so entries are dropped when the recorded
      `source` no longer exists.
    * **Empty tables.** The compiler emits a `.stringsdata` per source file
      whether or not it holds a localizable string, so most are `{"tables": {}}`
      noise. Dropping them keeps the sync command small and makes the reported
      count mean something.
    """
    if not DERIVED.exists():
        sys.exit("✗ No extraction build found. Run without --no-build first.")

    kept: list[Path] = []
    for path in DERIVED.rglob("*.stringsdata"):
        if any(marker in path.name for marker in EXCLUDED_FILE_MARKERS):
            continue
        # `.../Objects-normal/<arch>/Foo.stringsdata`
        if path.parent.name != arch:
            continue
        try:
            payload = json.loads(path.read_text())
        except (json.JSONDecodeError, OSError):
            # A file we cannot parse is one we cannot vouch for. Skipping is safer
            # than guessing, and the duplicate-key check below would not see its
            # keys anyway.
            continue
        source = payload.get("source", "")
        if not source or any(m in source for m in EXCLUDED_SOURCE_MARKERS):
            continue
        # Anything outside the repo is a dependency (SwiftPM checkouts live in
        # DerivedData), and its copy is not ours to translate.
        if not source.startswith(str(REPO)):
            continue
        if not Path(source).exists():
            continue
        if not any(payload.get("tables", {}).values()):
            continue
        kept.append(path)
    return sorted(kept)


def check_conflicts(files: list[Path]) -> int:
    """Report keys used with conflicting comments across modules.

    The same English string in two places is normally fine and desirable (one
    catalog entry, translated once). It becomes a problem when the two uses mean
    different things — then one translation cannot serve both and the string needs
    a semantic key with an explicit `defaultValue`. Disagreeing translator
    comments are the cheapest available signal for that, so we surface them rather
    than failing the run.
    """
    comments: dict[str, dict[str, set[str]]] = defaultdict(lambda: defaultdict(set))
    for path in files:
        payload = json.loads(path.read_text())
        source = payload.get("source", "")
        module = source.split("/Sources/")[1].split("/")[0] if "/Sources/" in source else "App"
        for entries in payload.get("tables", {}).values():
            for entry in entries:
                key, comment = entry.get("key"), (entry.get("comment") or "").strip()
                if key and comment:
                    comments[key][comment].add(module)

    conflicts = {k: v for k, v in comments.items() if len(v) > 1}
    for key, variants in sorted(conflicts.items()):
        print(f"⚠ '{key}' has conflicting translator comments:")
        for comment, modules in sorted(variants.items()):
            print(f"    {sorted(modules)}: {comment}")
    if conflicts:
        print("  → Give these a semantic key with an explicit defaultValue/comment.")
    return len(conflicts)



def validate_catalog() -> int:
    """Check the artifact translators actually receive.

    The guard's AST rule for brand names enumerated call sites, which meant a
    brand reaching the catalog by any path it didn't model went unnoticed — ten
    of them did. Validating the catalog instead checks the thing that matters:
    whatever the route, a brand must not end up in front of a translator.
    """
    catalog = json.loads(CATALOG.read_text())
    strings = catalog.get("strings", {})
    problems: list[str] = []

    config_path = REPO / "tools/l10n-guard.json"
    never_translate: set[str] = set()
    if config_path.exists():
        never_translate = set(json.loads(config_path.read_text()).get("neverTranslate", []))

    for brand in sorted(never_translate & set(strings)):
        problems.append(f"brand '{brand}' is translatable — render it with Text(verbatim:)")

    # Keys that carry no words for a translator to translate.
    for key in sorted(strings):
        stripped = key.strip()
        if not stripped or not any(ch.isalpha() for ch in stripped):
            problems.append(f"key {key!r} has no translatable content")

    problems += plural_problems(strings)
    problems += infoplist_problems()
    problems += language_release_problems(strings)

    for problem in problems:
        print(f"  ✗ {problem}")
    return len(problems)


# An integer placeholder. `%lld`/`%d`, optionally positional (`%2$lld`).
INT_PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(?:ll)?d")
ANY_PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(?:(?:ll)?d|@|f|#@[A-Za-z0-9_]+@)")


# Permission prompts are not in the app catalog: the system reads them from a
# per-target InfoPlist table. Each app target therefore owns one, and the English
# in it has to stay identical to the Info.plist it mirrors.
INFOPLIST_PAIRS = [
    (Path("App/Resources/InfoPlist.xcstrings"), Path("App/Resources/Info.plist")),
    (Path("App/PlozziOS/InfoPlist.xcstrings"), Path("App/PlozziOS/Info.plist")),
]

# Keys the system shows to a user, as opposed to configuration.
USER_FACING_INFOPLIST_KEYS = ("UsageDescription",)


def infoplist_problems() -> list[str]:
    """Catch an Info.plist prompt that was edited without its catalog.

    Nothing links the two files, so a reworded prompt would silently keep
    shipping the old translation in every language but English.
    """
    problems: list[str] = []
    for catalog_path, plist_path in INFOPLIST_PAIRS:
        catalog_file = REPO / catalog_path
        plist_file = REPO / plist_path
        if not catalog_file.exists() or not plist_file.exists():
            problems.append(f"{catalog_path} or {plist_path} is missing")
            continue
        catalog = json.loads(catalog_file.read_text()).get("strings", {})
        with plist_file.open("rb") as handle:
            plist = plistlib.load(handle)

        for key, value in plist.items():
            if not any(marker in key for marker in USER_FACING_INFOPLIST_KEYS):
                continue
            entry = catalog.get(key)
            if entry is None:
                problems.append(f"{plist_path}: {key} is user-facing but not in {catalog_path.name}")
                continue
            english = entry.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
            if english != value:
                problems.append(
                    f"{catalog_path.name}: {key} says {english!r} but {plist_path.name} says {value!r}"
                )

        for key in catalog:
            if key not in plist:
                problems.append(f"{catalog_path.name}: {key} is not in {plist_path.name}")
    return problems


def release_ready_languages() -> list[str]:
    """The exact set the in-app picker promises in release builds."""

    source = APP_LANGUAGE_SOURCE.read_text(encoding="utf-8")
    match = re.search(
        r"public\s+static\s+let\s+releaseReady:\s*\[String\]\s*=\s*\[(.*?)\]",
        source,
        re.DOTALL,
    )
    if match is None:
        raise RuntimeError(
            f"could not parse releaseReady from {APP_LANGUAGE_SOURCE.relative_to(REPO)}"
        )
    return re.findall(r'"([^"]+)"', match.group(1))


def localized_languages(strings: dict) -> set[str]:
    return {
        language
        for entry in strings.values()
        for language in entry.get("localizations", {})
        if language not in {"Base", "en"}
    }


def language_release_problems(
    strings: dict,
    release_ready: list[str] | None = None,
    info_documents: dict[Path, dict] | None = None,
) -> list[str]:
    """Make the release gate equal the languages the OS actually sees.

    `releaseReady` controls only Plozz's picker. iOS/tvOS and App Store inspect
    bundled `.lproj` directories directly, so a partial language in the catalog
    ships even when the picker hides it. The only safe invariant is exact parity:
    every non-English catalog language is complete, permission-localized, and in
    `releaseReady`; nothing else is bundled.
    """

    problems: list[str] = []
    if release_ready is None:
        try:
            release_ready = release_ready_languages()
        except RuntimeError as error:
            return [str(error)]
    release_set = set(release_ready)
    if len(release_set) != len(release_ready):
        problems.append("AppLanguage.releaseReady contains duplicate tags")

    app_languages = localized_languages(strings)
    if app_languages != release_set:
        problems.append(
            "app catalog languages must exactly match AppLanguage.releaseReady; "
            f"catalog-only={sorted(app_languages - release_set)}, "
            f"release-only={sorted(release_set - app_languages)}"
        )

    for language in sorted(app_languages):
        missing = [
            key
            for key, entry in strings.items()
            if language not in entry.get("localizations", {})
        ]
        if missing:
            problems.append(
                f"{language}: app catalog is missing {len(missing)} key(s), "
                f"first: {missing[:5]}"
            )

    for catalog_path, _ in INFOPLIST_PAIRS:
        document = (
            info_documents[catalog_path]
            if info_documents is not None
            else json.loads((REPO / catalog_path).read_text(encoding="utf-8"))
        )
        info_strings = document.get("strings", {})
        info_languages = localized_languages(info_strings)
        if info_languages != release_set:
            problems.append(
                f"{catalog_path.name} languages must exactly match releaseReady; "
                f"catalog-only={sorted(info_languages - release_set)}, "
                f"release-only={sorted(release_set - info_languages)}"
            )
        for key, entry in info_strings.items():
            missing = release_set - set(entry.get("localizations", {}))
            if missing:
                problems.append(
                    f"{catalog_path.name}: {key} missing {sorted(missing)}"
                )
    return problems


def report_coverage() -> None:
    """Per-language coverage — the input to the release-readiness decision.

    `AppLanguage.releaseReady` decides which languages the picker offers, and
    that has to be a judgement rather than "an .lproj exists": a bundled
    localization only means SOME strings were translated. Spanish sat at 6% with
    its folder present, and offering that shows a mostly-English UI to someone
    who asked for Spanish.

    Reports two different facts instead of collapsing them into one percentage:

    - available: the key has a localization and will render in that language;
    - reviewed: every string unit is in Apple's `translated` state.

    Model-produced `needs_review` text therefore counts as available but not
    reviewed. This preserves honest provenance without reporting a complete,
    usable model translation as 0% coverage.
    """
    catalog = json.loads(CATALOG.read_text())
    strings = catalog.get("strings", {})
    source = catalog.get("sourceLanguage", "en")

    translatable = {k: v for k, v in strings.items() if v.get("shouldTranslate") is not False}
    languages = {
        language
        for entry in translatable.values()
        for language in entry.get("localizations", {})
        if language != source
    }

    total = len(translatable)
    print(f"\u25b8 {total} translatable key(s); source language {source}")
    if not languages:
        print("  (no translations yet)")
        return

    for language in sorted(languages):
        states: dict[str, int] = defaultdict(int)
        available = 0
        reviewed = 0
        for entry in translatable.values():
            localization = entry.get("localizations", {}).get(language)
            if localization is None:
                states["missing"] += 1
                continue
            available += 1
            units = [
                value
                for value in walk_string_units(localization)
                if isinstance(value, dict)
            ]
            unit_states = {unit.get("state", "new") for unit in units}
            if unit_states == {"translated"}:
                reviewed += 1
                states["translated"] += 1
            elif "needs_review" in unit_states:
                states["needs_review"] += 1
            else:
                states[", ".join(sorted(unit_states)) or "new"] += 1

        available_percent = 100 * available / total if total else 0
        reviewed_percent = 100 * reviewed / total if total else 0
        detail = ", ".join(
            f"{state} {count}"
            for state, count in sorted(states.items())
            if state != "translated"
        )
        print(
            f"  {language:<8} available {available_percent:5.1f}% "
            f"({available}/{total}), reviewed {reviewed_percent:5.1f}% "
            f"({reviewed}/{total})"
            + (f"  [{detail}]" if detail else "")
        )


def walk_string_units(value: object) -> list[dict]:
    """Every nested String Catalog stringUnit below *value*."""

    result: list[dict] = []
    if isinstance(value, dict):
        unit = value.get("stringUnit")
        if isinstance(unit, dict):
            result.append(unit)
        for key, child in value.items():
            if key != "stringUnit":
                result.extend(walk_string_units(child))
    elif isinstance(value, list):
        for child in value:
            result.extend(walk_string_units(child))
    return result

def plural_problems(strings: dict) -> list[str]:
    """Flag counts that no translator can fix from the catalog.

    A key like "%lld episodes" is only correct in languages with English's two
    plural forms. Polish has four and Arabic six, and a translator handed a
    single flat string has nowhere to put them — the variations have to exist in
    the catalog. This also checks that every variation keeps the placeholders of
    the string it replaces, because a dropped specifier is a crash, not a typo.
    """
    problems: list[str] = []

    # Counts that are identifiers or measurements, not quantities of a noun.
    exempt = {
        "%lld", "%lld%%", "%lld of %lld", "Items: %lld", ":%lld", "%lld sec",
        "Episode %lld", "Track %lld", "Downloading %lld%%", "Downloading %lld percent",
        "Left %lld%%", "Right %lld%%", "%lld queued", "%lld unavailable",
        "+ %lld more", "· +%lld more",
        # PIN entry positions — "PIN 1 of 2", "PIN progress: 2 of 4". Same family
        # as "Episode %lld": an index, not a count of anything.
        "PIN %lld of %lld", "PIN progress: %lld of %lld",
        "The media server returned HTTP %lld instead of a media file.",
    }

    for key in sorted(strings):
        if key in exempt or not INT_PLACEHOLDER.search(key):
            continue
        english = strings[key].get("localizations", {}).get("en", {})
        variations = english.get("variations", {}).get("plural")
        substitutions = english.get("substitutions", {})
        if not variations and not substitutions:
            problems.append(
                f"key {key!r} counts something but has no plural variations — "
                "add them in Xcode's catalog editor (Vary by Plural)"
            )
            continue

        expected = sorted(ANY_PLACEHOLDER.findall(key))
        for label, unit in plural_units(english):
            found = sorted(ANY_PLACEHOLDER.findall(unit))
            if variations and found != expected:
                problems.append(
                    f"key {key!r} variation {label!r} has placeholders {found} "
                    f"but the key has {expected}"
                )
    return problems


def plural_units(english: dict) -> list[tuple[str, str]]:
    """Every (category, value) pair under a localization's plural variations."""
    units: list[tuple[str, str]] = []
    for category, unit in english.get("variations", {}).get("plural", {}).items():
        value = unit.get("stringUnit", {}).get("value")
        if value is not None:
            units.append((category, value))
    for name, substitution in english.get("substitutions", {}).items():
        for category, unit in substitution.get("variations", {}).get("plural", {}).items():
            value = unit.get("stringUnit", {}).get("value")
            if value is not None:
                units.append((f"{name}.{category}", value))
    return units


def sync(files: list[Path], allow_stale: bool) -> None:
    """Hand the selected `.stringsdata` to `xcstringstool sync`.

    The file list is passed via short symlinks in a temp directory rather than
    absolute paths. DerivedData paths run ~150 characters each, and with enough
    inputs the argv blows past `ARG_MAX` ("Argument list too long"). Batching
    would be wrong here: stale marking is computed against the strings present in
    ONE invocation, so a batched run would mark each batch's strings stale from
    the others' perspective. One call, short names.
    """
    with tempfile.TemporaryDirectory(prefix="plozz-l10n-") as tmp:
        tmpdir = Path(tmp)
        names: list[str] = []
        for index, path in enumerate(files):
            link = tmpdir / f"{index:05d}.stringsdata"
            link.symlink_to(path)
            names.append(link.name)

        cmd = ["xcrun", "xcstringstool", "sync", str(CATALOG)]
        for name in names:
            cmd += ["--stringsdata", name]
        if not allow_stale:
            cmd.append("--skip-marking-strings-stale")

        proc = subprocess.run(cmd, cwd=tmpdir, text=True, capture_output=True)
        if proc.returncode != 0:
            sys.exit(f"✗ xcstringstool sync failed:\n{proc.stdout}{proc.stderr}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true",
                        help="Fail if syncing would change the catalog (for CI).")
    parser.add_argument("--platform", choices=sorted(PLATFORMS),
                        help="Extract from one platform only. Faster, but never prunes.")
    parser.add_argument("--no-build", action="store_true",
                        help="Reuse the previous extraction build.")
    parser.add_argument("--validate-only", action="store_true",
                        help="Check the committed catalog without extracting anything (for CI).")
    parser.add_argument("--coverage", action="store_true",
                        help="Report per-language translation coverage and exit.")
    parser.add_argument("--clean", action="store_true",
                        help="Wipe the localization DerivedData first.")
    parser.add_argument("--quiet", action="store_true", default=True,
                        help="Suppress xcodebuild output unless it fails.")
    parser.add_argument("--verbose", dest="quiet", action="store_false")
    args = parser.parse_args()

    if not CATALOG.exists():
        sys.exit(f"✗ Missing catalog: {CATALOG.relative_to(REPO)}")

    # Validation reads only the committed catalog, so it needs no toolchain and
    # no extraction. That is what makes it usable on a fresh CI runner, where
    # there is no DerivedData to reuse and a full --check would mean building
    # both platforms again purely to prove freshness.
    if args.coverage:
        report_coverage()
        return 0

    if args.validate_only:
        problems = validate_catalog()
        if problems:
            print(f"✗ {problems} catalog problem(s).", file=sys.stderr)
            return 1
        print("✓ Catalog validates.")
        return 0

    if shutil.which("xcrun") is None:
        sys.exit("✗ xcrun not found — Xcode command line tools are required.")

    platform_keys = [args.platform] if args.platform else sorted(PLATFORMS)
    # Stale marking deletes catalog entries the build did not see, so it is only
    # safe when THIS run demonstrably produced the full tvOS + iOS union.
    # Deriving it from the argument list alone was a bug: `--platform tvos`
    # followed by a plain `--no-build` would reuse tvOS-only output and happily
    # prune every iOS-only string.
    allow_stale = args.platform is None and not args.no_build

    if args.clean and DERIVED.exists():
        shutil.rmtree(DERIVED)
    if not args.no_build:
        build_for_extraction(platform_keys, args.quiet)

    files = collect_stringsdata(ARCH)
    if args.no_build and args.platform is None:
        print("▸ --no-build: reusing cached extraction, so stale marking is skipped "
              "(cannot prove both platforms are represented)")
    if not files:
        sys.exit("✗ No .stringsdata found. Extraction did not run — check "
                 "defaultLocalization in Package.swift and SWIFT_EMIT_LOC_STRINGS.")
    print(f"▸ {len(files)} .stringsdata files from {', '.join(platform_keys)} ({ARCH})")

    before = CATALOG.read_text()
    conflicts = check_conflicts(files)
    sync(files, allow_stale=allow_stale)
    after = CATALOG.read_text()

    if args.check:
        conflicts += validate_catalog()
        if before != after:
            CATALOG.write_text(before)  # leave the tree as we found it
            print("✗ Catalog is out of date. Run tools/l10n-sync.py and commit.",
                  file=sys.stderr)
            return 1
        print("✓ Catalog is up to date.")
        return 1 if conflicts else 0

    keys = len(json.loads(after).get("strings", {}))
    verb = "unchanged" if before == after else "updated"
    print(f"✓ Catalog {verb} — {keys} keys"
          + ("" if allow_stale else " (stale marking skipped: partial scope)"))
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main())
