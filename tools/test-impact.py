#!/usr/bin/env python3
"""test-impact.py — data-driven test selection for Plozz.

The single source of truth for "which test targets cover a change". It reads the
package graph from `swift package dump-package` at runtime (NEVER a hardcoded
target list), so it stays correct as targets are added or removed — e.g. when the
WebDAV work adds `MediaTransportWebDAV` + `MediaTransportWebDAVTests`, both this
selector and `run-tests.sh` pick it up with no edits here.

How selection works:
  1. Build the internal target dependency graph from dump-package.
  2. For each *test* target, compute the transitive closure of source targets it
     reaches, then invert that into  sourceModule -> {covering test targets}.
     Because CoreModels/CoreNetworking/MediaTransportCore are depended on by many
     targets, a change to one of them naturally selects everything that depends on
     it — "foundational escalation" falls out of the data with no special-casing.
  3. Map changed files (git diff) to a selection, with guardrails that FORCE the
     full matrix whenever the change could invalidate the map itself or is
     otherwise unmappable (see classify_file). We never silently skip tests.

Modes:
  test-impact.py --list-tests            # print every test target, one per line
  test-impact.py --resolve NAME...       # map module|suite names -> suite names
  test-impact.py [--base REF] [--staged] # print a selection directive from a diff
  test-impact.py --files-stdin           # select from newline-separated paths on
                                         #   stdin (no git) — for dry-runs/tests

Selection stdout contract (machine-readable), reasons go to stderr:
  ALL                 -> run the full matrix
  SELECT\n<suite>...  -> run exactly these suites
  NONE                -> nothing to run (docs/assets-only change)

Env:
  PLOZZ_DUMP_JSON=<path>  use a pre-dumped package JSON instead of shelling out to
                          `swift package dump-package` (used by tests / dry-runs).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys


def _dump_package() -> dict:
    """Load the package manifest, preferring a pre-dumped JSON when provided."""
    override = os.environ.get("PLOZZ_DUMP_JSON")
    if override:
        with open(override) as fh:
            return json.load(fh)
    # Keep the git override the rest of the build chain relies on (bare-repo tags).
    env = dict(os.environ)
    env.setdefault("GIT_CONFIG_PARAMETERS", "'safe.bareRepository=all'")
    out = subprocess.run(
        ["swift", "package", "dump-package"],
        check=True, capture_output=True, text=True, env=env,
    ).stdout
    return json.loads(out)


class Graph:
    def __init__(self, manifest: dict):
        self.targets = {t["name"]: t for t in manifest.get("targets", [])}
        self.names = set(self.targets)
        self.tests = sorted(
            n for n, t in self.targets.items() if t.get("type") == "test"
        )

    def _direct_deps(self, name: str) -> set[str]:
        """Internal (in-package) target dependencies of `name`; externals ignored."""
        deps: set[str] = set()
        for d in self.targets[name].get("dependencies", []):
            for key in ("byName", "target"):
                val = d.get(key)
                if val and val[0] in self.names:
                    deps.add(val[0])
        return deps

    def _closure(self, name: str) -> set[str]:
        seen: set[str] = set()
        stack = [name]
        while stack:
            cur = stack.pop()
            for dep in self._direct_deps(cur):
                if dep not in seen:
                    seen.add(dep)
                    stack.append(dep)
        return seen

    def coverage_map(self) -> dict[str, set[str]]:
        """sourceModule -> set of test targets that transitively cover it.

        A test target always covers itself and every internal target it reaches.
        """
        rev: dict[str, set[str]] = {}
        for tt in self.tests:
            for src in self._closure(tt) | {tt}:
                rev.setdefault(src, set()).add(tt)
        return rev

    def suite_for_module(self, module: str) -> str | None:
        """The test target that IS a module's own suite, data-driven.

        A module `Foo` has suite `FooTests` iff that test target exists.
        """
        cand = f"{module}Tests"
        if cand in self.targets and self.targets[cand].get("type") == "test":
            return cand
        # Already a test target name?
        if module in self.targets and self.targets[module].get("type") == "test":
            return module
        return None


# --- change classification ---------------------------------------------------

def classify_file(path: str):
    """Classify a changed path.

    Returns one of:
      ("full", reason)          -> force the whole matrix
      ("module", name)          -> source module changed
      ("suite", name)           -> a specific test target changed
      ("ignore", None)          -> no test impact (docs/assets)
    """
    # Guardrails: changes that can invalidate the selection map itself, or that
    # touch build/test/CI infrastructure, escalate to the full matrix.
    if path in ("Package.swift", "Package.resolved"):
        return ("full", "package manifest/graph changed")
    if path == "project.yml" or path.startswith("Config/"):
        return ("full", "project generation/config changed")
    if path.startswith("tools/"):
        return ("full", "build/test tooling changed")
    if path.startswith(".github/"):
        return ("full", "CI configuration changed")
    if path.endswith(".xctestplan"):
        return ("full", "test plan changed")

    # No test impact.
    if path.startswith("docs/") or path.endswith(".md"):
        return ("ignore", None)
    if path in (".gitignore", ".gitattributes", "LICENSE", ".swiftlint.yml"):
        return ("ignore", None)
    if path.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".svg", ".pdf",
                              ".xcassets", ".json5", ".strings")):
        # Asset/localization files carry no SPM unit-test coverage.
        return ("ignore", None)

    # Mapped code paths.
    parts = path.split("/")
    if len(parts) >= 2 and parts[0] == "Sources":
        return ("module", parts[1])
    if len(parts) >= 2 and parts[0] == "Tests":
        return ("suite", parts[1])

    # Anything else (App/, unknown top-level dirs, root scripts) is a code path we
    # cannot confidently map -> be safe and run everything.
    return ("full", f"unmapped code path ({path})")


def _changed_files(base: str, staged: bool) -> list[str]:
    def run(args):
        r = subprocess.run(["git", *args], capture_output=True, text=True)
        return [l for l in r.stdout.splitlines() if l.strip()]

    if staged:
        return sorted(set(run(["diff", "--cached", "--name-only"])))
    mb = subprocess.run(["git", "merge-base", base, "HEAD"],
                        capture_output=True, text=True)
    mergebase = mb.stdout.strip() or base
    files = set()
    files.update(run(["diff", "--name-only", f"{mergebase}...HEAD"]))
    files.update(run(["diff", "--name-only"]))          # unstaged
    files.update(run(["diff", "--cached", "--name-only"]))  # staged
    return sorted(files)


def select(graph: Graph, files: list[str]):
    """Return (directive, suites, reasons). directive in {ALL, SELECT, NONE}."""
    reasons: list[str] = []
    if not files:
        reasons.append("No changed files detected.")
        return ("NONE", [], reasons)

    cover = graph.coverage_map()
    suites: set[str] = set()
    force_full = False

    for f in files:
        kind, info = classify_file(f)
        if kind == "full":
            reasons.append(f"FULL  <- {f}: {info}")
            force_full = True
        elif kind == "module":
            mod = info
            hits = cover.get(mod)
            if hits:
                suites |= hits
                reasons.append(
                    f"src   {f}: module {mod} -> {', '.join(sorted(hits))}")
            else:
                # A source module with no covering test target anywhere. Not a
                # docs file, so don't silently skip — escalate to be safe.
                reasons.append(
                    f"FULL  <- {f}: source module {mod} has no covering test "
                    f"target (unmapped) — running full to be safe")
                force_full = True
        elif kind == "suite":
            suite = info
            if suite in graph.targets and graph.targets[suite].get("type") == "test":
                suites.add(suite)
                reasons.append(f"test  {f}: -> {suite}")
            else:
                reasons.append(
                    f"FULL  <- {f}: Tests/{suite} is not a known test target")
                force_full = True
        else:  # ignore
            reasons.append(f"skip  {f}: no test impact")

    if force_full:
        return ("ALL", graph.tests, reasons)
    if not suites:
        return ("NONE", [], reasons)
    return ("SELECT", sorted(suites), reasons)


# --- CLI ----------------------------------------------------------------------

def main(argv: list[str]) -> int:
    args = argv[1:]

    if "--list-tests" in args:
        graph = Graph(_dump_package())
        print("\n".join(graph.tests))
        return 0

    if args and args[0] == "--resolve":
        graph = Graph(_dump_package())
        rc = 0
        for name in args[1:]:
            suite = graph.suite_for_module(name)
            if suite:
                print(suite)
            else:
                print(f"test-impact: '{name}' has no covering test target — skipping",
                      file=sys.stderr)
                rc = 1
        return rc

    base = "origin/main"
    staged = False
    files_stdin = False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--staged":
            staged = True
        elif a == "--files-stdin":
            files_stdin = True
        elif a == "--base":
            base = args[i + 1]; i += 1
        elif a.startswith("--base="):
            base = a.split("=", 1)[1]
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print(f"test-impact: unknown argument {a}", file=sys.stderr)
            return 2
        i += 1

    graph = Graph(_dump_package())
    if files_stdin:
        files = sorted({l.strip() for l in sys.stdin if l.strip()})
    else:
        files = _changed_files(base, staged)
    directive, suites, reasons = select(graph, files)

    print("── test-impact selection ─────────────────────────────", file=sys.stderr)
    for r in reasons:
        print("  " + r, file=sys.stderr)
    if directive == "ALL":
        print(f"  => FULL matrix: {len(suites)} test targets", file=sys.stderr)
    elif directive == "SELECT":
        print(f"  => {len(suites)} suite(s): {', '.join(suites)}", file=sys.stderr)
    else:
        print("  => nothing to run", file=sys.stderr)
    print("──────────────────────────────────────────────────────", file=sys.stderr)

    if directive == "SELECT":
        print("SELECT")
        print("\n".join(suites))
    else:
        print(directive)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
