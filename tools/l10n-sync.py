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
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "App/Resources/Localizable.xcstrings"
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
    parser.add_argument("--clean", action="store_true",
                        help="Wipe the localization DerivedData first.")
    parser.add_argument("--quiet", action="store_true", default=True,
                        help="Suppress xcodebuild output unless it fails.")
    parser.add_argument("--verbose", dest="quiet", action="store_false")
    args = parser.parse_args()

    if not CATALOG.exists():
        sys.exit(f"✗ Missing catalog: {CATALOG.relative_to(REPO)}")
    if shutil.which("xcrun") is None:
        sys.exit("✗ xcrun not found — Xcode command line tools are required.")

    platform_keys = [args.platform] if args.platform else sorted(PLATFORMS)
    # Stale marking deletes catalog entries the build did not see. Only safe with
    # the full tvOS + iOS union; a single-platform run would prune the other's copy.
    allow_stale = args.platform is None

    if args.clean and DERIVED.exists():
        shutil.rmtree(DERIVED)
    if not args.no_build:
        build_for_extraction(platform_keys, args.quiet)

    files = collect_stringsdata(ARCH)
    if not files:
        sys.exit("✗ No .stringsdata found. Extraction did not run — check "
                 "defaultLocalization in Package.swift and SWIFT_EMIT_LOC_STRINGS.")
    print(f"▸ {len(files)} .stringsdata files from {', '.join(platform_keys)} ({ARCH})")

    before = CATALOG.read_text()
    conflicts = check_conflicts(files)
    sync(files, allow_stale=allow_stale)
    after = CATALOG.read_text()

    if args.check:
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
