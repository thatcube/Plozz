#!/usr/bin/env python3
"""arch-guard.py — automated module-layering guard for Plozz.

Plozz's ~34-module Swift package has a deliberately clean, ACYCLIC layering:

    CoreModels (leaf)
      -> CoreNetworking / CoreUI / MetadataKit
        -> Providers / Services
          -> Features
            -> AppShell

Until now that layering was preserved only by discipline + review. This guard
makes it mechanical: it FAILS the build the moment a branch adds a forbidden
edge (e.g. one Feature importing another, a Provider reaching up into a Feature,
CoreModels growing a dependency, or a heavy vendor SDK leaking out of its
designated leaf module).

Why a Python host-side check and not a Swift XCTest?
  `swift test` is unusable in this repo (tvOS-only xcframeworks), so every unit
  test runs inside the tvOS Simulator sandbox, which cannot read the repo's
  Sources/ tree or shell out to `swift package dump-package`. So a Swift test
  bundle literally can't introspect the module graph. Instead we mirror the
  established `tools/test-impact.py` pattern: parse `swift package dump-package`
  on the HOST so the guard stays DATA-DRIVEN — new targets are picked up
  automatically with no edits here.

What it checks:
  1. No Feature -> Feature dependency/import, except the one declared exception
     FeatureSettings -> FeatureProfiles.
  2. No Provider* / *Service target depends on / imports any Feature*.
  3. CoreModels is a true leaf: it has ZERO internal-target dependencies.
  4. Heavy vendor SDKs stay confined to their designated owner module(s)
     (+ that owner's *Tests target). See VENDOR_OWNERS.
  5. The internal module graph stays acyclic (a DAG).

Rules 1-3 are enforced on the AUTHORITATIVE declared graph from dump-package
(in SwiftPM you can only `import` a declared direct dependency, so the manifest
is the source of truth). A secondary import-scan of Sources/**/*.swift provides
defense-in-depth + clearer, file-level error locations, and independently
enforces the vendor-confinement rule.

Usage:
  tools/arch-guard.py            # check the package; exit 1 on any violation
  tools/arch-guard.py --self-test  # run embedded fixtures proving guard logic
  tools/arch-guard.py -h

Env:
  PLOZZ_DUMP_JSON=<path>  use a pre-dumped package JSON instead of shelling out
                          to `swift package dump-package` (used by --self-test
                          and CI dry-runs), mirroring tools/test-impact.py.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

# --- Declarative policy (the intent lives here) ------------------------------
# Editing anything below is a conscious, reviewed relaxation of the layering.

# The single sanctioned cross-Feature edge (declared in Package.swift too).
ALLOWED_FEATURE_EDGES = {
    ("FeatureSettings", "FeatureProfiles"),
}

# Heavy third-party SDKs and the ONLY internal modules allowed to link/import
# them. Keyed by the product/module name as it appears both in the manifest
# (`{"product": ["<name>", "<package>", ...]}`) and in `import <name>` source
# lines. The owner's `<Owner>Tests` target is implicitly allowed too.
VENDOR_OWNERS = {
    "YouTubeKit": {"ProviderTrailers"},
    "Sentry": {"CrashReporting"},          # package: sentry-cocoa
    "SMBClient": {"ProviderShare", "MediaTransportSMB"},
    "NIOSSH": {"MediaTransportSFTP"},      # package: swift-nio-ssh
    "AetherEngine": {"EnginePlozzigen"},
}

# Submodule-import kind keywords: `import struct Foo.Bar` -> module is `Foo`.
_IMPORT_KINDS = {
    "struct", "class", "enum", "protocol", "func", "var", "let",
    "typealias", "actor",
}
_IMPORT_RE = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*import\s+(.+)$"
)


def _strip_comments_and_strings(lines: list[str]) -> list[str]:
    """Blank out block comments (nesting-aware), triple-quoted multiline
    strings, `//` line comments, and inline double-quoted string literals, so the
    import scanner never matches an `import`-looking line that is actually inside
    a comment or a string. Returns a same-length list (line numbers preserved).

    This is a deliberately small lexer: it doesn't need to be a full Swift
    tokenizer, only good enough that a stray `import Foo` inside a doc comment or
    a code-snippet string literal can't produce a false CI failure.
    """
    out: list[str] = []
    in_block = 0          # /* */ nesting depth
    in_multiline_str = False  # inside a """ ... """ literal
    for raw in lines:
        buf: list[str] = []
        i, n = 0, len(raw)
        while i < n:
            two = raw[i:i + 2]
            three = raw[i:i + 3]
            if in_multiline_str:
                if three == '"""':
                    in_multiline_str = False
                    i += 3
                else:
                    i += 1
                continue
            if in_block:
                if two == "*/":
                    in_block -= 1
                    i += 2
                elif two == "/*":
                    in_block += 1
                    i += 2
                else:
                    i += 1
                continue
            # Not currently inside a block comment or multiline string.
            if three == '"""':
                in_multiline_str = True
                i += 3
                continue
            if two == "/*":
                in_block += 1
                i += 2
                continue
            if two == "//":
                break  # rest of line is a comment
            if raw[i] == '"':
                # Skip a single-line string literal (handles \" escapes).
                i += 1
                while i < n and raw[i] != '"':
                    if raw[i] == "\\":
                        i += 2
                    else:
                        i += 1
                i += 1
                continue
            buf.append(raw[i])
            i += 1
        out.append("".join(buf))
    return out


# --- Name-based layer classification -----------------------------------------

def is_feature(name: str) -> bool:
    return name.startswith("Feature")


def is_provider(name: str) -> bool:
    return name.startswith("Provider")


def is_service(name: str) -> bool:
    return name.endswith("Service")


def vendor_allowed_targets(vendor: str) -> set[str]:
    owners = VENDOR_OWNERS[vendor]
    return owners | {f"{o}Tests" for o in owners}


# --- Manifest model ----------------------------------------------------------

class Package:
    def __init__(self, manifest: dict):
        self.targets = {t["name"]: t for t in manifest.get("targets", [])}
        self.names = set(self.targets)

    def is_test(self, name: str) -> bool:
        return self.targets.get(name, {}).get("type") == "test"

    def internal_deps(self, name: str) -> list[str]:
        deps: list[str] = []
        for d in self.targets[name].get("dependencies", []):
            for key in ("byName", "target"):
                val = d.get(key)
                if val and val[0] in self.names:
                    deps.append(val[0])
        return deps

    def product_deps(self, name: str) -> list[str]:
        """External product names declared by a target."""
        out: list[str] = []
        for d in self.targets[name].get("dependencies", []):
            val = d.get("product")
            if val:
                out.append(val[0])
        return out


def _dump_package() -> dict:
    override = os.environ.get("PLOZZ_DUMP_JSON")
    if override:
        with open(override) as fh:
            return json.load(fh)
    env = dict(os.environ)
    env.setdefault("GIT_CONFIG_PARAMETERS", "'safe.bareRepository=all'")
    out = subprocess.run(
        ["swift", "package", "dump-package"],
        check=True, capture_output=True, text=True, env=env,
    ).stdout
    return json.loads(out)


# --- Rule checks -------------------------------------------------------------

def check_manifest(pkg: Package) -> list[str]:
    """Enforce rules 1-4 on the declared dependency graph. Returns violations."""
    v: list[str] = []

    for name in sorted(pkg.names):
        is_target_test = pkg.is_test(name)

        # Rule 4 (vendor confinement) — applies to every target (incl. tests,
        # via the *Tests allowance baked into vendor_allowed_targets).
        for product in pkg.product_deps(name):
            if product in VENDOR_OWNERS and name not in vendor_allowed_targets(product):
                v.append(
                    f"[vendor] target '{name}' depends on heavy vendor product "
                    f"'{product}', which is confined to "
                    f"{sorted(VENDOR_OWNERS[product])} (+ their *Tests). "
                    f"Keep '{product}' isolated in its designated leaf module."
                )

        # Layering rules 1-3 apply to shipping (regular) targets only; test
        # targets legitimately fan out across modules.
        if is_target_test:
            continue

        deps = pkg.internal_deps(name)

        # Rule 3: CoreModels is a leaf.
        if name == "CoreModels" and deps:
            v.append(
                f"[leaf] CoreModels must have NO internal dependencies but "
                f"declares: {sorted(deps)}. CoreModels is the graph's leaf."
            )

        for dep in deps:
            # Rule 1: Feature -> Feature (except the sanctioned edge).
            if is_feature(name) and is_feature(dep) and name != dep:
                if (name, dep) not in ALLOWED_FEATURE_EDGES:
                    v.append(
                        f"[feature->feature] '{name}' depends on '{dep}'. "
                        f"Features must not depend on other Features (only "
                        f"sanctioned edge: FeatureSettings -> FeatureProfiles)."
                    )
            # Rule 2: Provider/Service -> Feature.
            if (is_provider(name) or is_service(name)) and is_feature(dep):
                kind = "Provider" if is_provider(name) else "Service"
                v.append(
                    f"[{kind.lower()}->feature] '{name}' depends on Feature "
                    f"'{dep}'. {kind}s must not reach up into Feature modules."
                )
    return v


def check_acyclic(pkg: Package) -> list[str]:
    """Rule 5: the internal target graph must be a DAG."""
    WHITE, GREY, BLACK = 0, 1, 2
    color = {n: WHITE for n in pkg.names}
    violations: list[str] = []

    def visit(n: str, stack: list[str]) -> None:
        color[n] = GREY
        stack.append(n)
        for dep in pkg.internal_deps(n):
            if color[dep] == GREY:
                i = stack.index(dep)
                cycle = " -> ".join(stack[i:] + [dep])
                violations.append(f"[cycle] dependency cycle: {cycle}")
            elif color[dep] == WHITE:
                visit(dep, stack)
        stack.pop()
        color[n] = BLACK

    for n in sorted(pkg.names):
        if color[n] == WHITE:
            visit(n, [])
    # De-dup (a cycle can be discovered from multiple entry points).
    return sorted(set(violations))


def _imported_module(rest: str) -> str | None:
    """Extract the top-level module name from the text after `import `."""
    toks = rest.strip().split()
    if not toks:
        return None
    first = toks[0]
    if first in _IMPORT_KINDS and len(toks) > 1:
        first = toks[1]
    # `import Foo.Bar` / `import struct Foo.Bar` -> module is `Foo`.
    module = first.split(".")[0]
    # Strip any trailing punctuation/comment noise.
    module = re.split(r"[^A-Za-z0-9_]", module)[0]
    return module or None


def check_imports(pkg: Package, sources_root: str) -> list[str]:
    """Defense-in-depth: scan Sources/**/*.swift and enforce rules 1,2,4 on the
    actual `import` statements, with file-level locations."""
    v: list[str] = []
    if not os.path.isdir(sources_root):
        return v
    vendor_modules = set(VENDOR_OWNERS)

    for target in sorted(os.listdir(sources_root)):
        tdir = os.path.join(sources_root, target)
        if not os.path.isdir(tdir):
            continue
        # Only shipping targets live under Sources/; skip unknown dirs.
        if target not in pkg.names or pkg.is_test(target):
            continue

        for dirpath, _dirs, files in os.walk(tdir):
            for fn in files:
                if not fn.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, os.path.dirname(sources_root))
                try:
                    with open(path, encoding="utf-8") as fh:
                        lines = fh.readlines()
                except (OSError, UnicodeDecodeError):
                    continue
                # Neutralise comments/strings so an `import`-looking line inside
                # a comment or string literal can't be misread as a real import.
                scan = _strip_comments_and_strings(lines)
                for lineno, line in enumerate(scan, 1):
                    m = _IMPORT_RE.match(line)
                    if not m:
                        continue
                    mod = _imported_module(m.group(1))
                    if not mod:
                        continue
                    # Rule 4: vendor confinement (source-level).
                    if mod in vendor_modules and target not in vendor_allowed_targets(mod):
                        v.append(
                            f"[vendor] {rel}:{lineno}: '{target}' imports heavy "
                            f"vendor module '{mod}' (confined to "
                            f"{sorted(VENDOR_OWNERS[mod])})."
                        )
                    # Rule 1: Feature -> Feature.
                    if mod in pkg.names and is_feature(target) and is_feature(mod) and mod != target:
                        if (target, mod) not in ALLOWED_FEATURE_EDGES:
                            v.append(
                                f"[feature->feature] {rel}:{lineno}: '{target}' "
                                f"imports Feature '{mod}'."
                            )
                    # Rule 2: Provider/Service -> Feature.
                    if mod in pkg.names and (is_provider(target) or is_service(target)) and is_feature(mod):
                        kind = "provider" if is_provider(target) else "service"
                        v.append(
                            f"[{kind}->feature] {rel}:{lineno}: '{target}' "
                            f"imports Feature '{mod}'."
                        )
    return v


def run_checks(manifest: dict, sources_root: str) -> list[str]:
    pkg = Package(manifest)
    violations: list[str] = []
    violations += check_manifest(pkg)
    violations += check_acyclic(pkg)
    violations += check_imports(pkg, sources_root)
    return violations


# --- Self-test ---------------------------------------------------------------

def _target(name, deps=None, products=None, ttype="regular"):
    d = [{"byName": [x, None]} for x in (deps or [])]
    d += [{"product": [p, p, None, None]} for p in (products or [])]
    return {"name": name, "type": ttype, "dependencies": d}


def _self_test() -> int:
    cases: list[tuple[str, dict, bool]] = []

    # Clean graph — must pass.
    cases.append((
        "clean",
        {"targets": [
            _target("CoreModels"),
            _target("CoreNetworking", ["CoreModels"]),
            _target("ProviderJellyfin", ["CoreModels", "CoreNetworking"]),
            _target("RatingsService", ["CoreModels"]),
            _target("FeatureHome", ["CoreModels", "RatingsService"]),
            _target("FeatureSettings", ["CoreModels", "FeatureProfiles"]),
            _target("FeatureProfiles", ["CoreModels"]),
            _target("ProviderTrailers", ["CoreModels"], ["YouTubeKit"]),
            _target("EnginePlozzigen", ["CoreModels", "FeaturePlayback"], ["AetherEngine"]),
            _target("FeaturePlayback", ["CoreModels"]),
            _target("EnginePlozzigenTests", ["EnginePlozzigen"], ["AetherEngine"], "test"),
            _target("ProviderJellyfinTests", ["ProviderJellyfin", "ProviderPlex"], None, "test"),
            _target("ProviderPlex", ["CoreModels"]),
        ]},
        False,
    ))
    # Rule 1: Feature -> Feature (unsanctioned).
    cases.append((
        "feature->feature",
        {"targets": [_target("CoreModels"),
                     _target("FeatureHome", ["CoreModels", "FeatureSearch"]),
                     _target("FeatureSearch", ["CoreModels"])]},
        True,
    ))
    # Rule 1 exception must NOT flag.
    cases.append((
        "feature-exception",
        {"targets": [_target("CoreModels"),
                     _target("FeatureSettings", ["CoreModels", "FeatureProfiles"]),
                     _target("FeatureProfiles", ["CoreModels"])]},
        False,
    ))
    # Rule 2: Provider -> Feature.
    cases.append((
        "provider->feature",
        {"targets": [_target("CoreModels"),
                     _target("ProviderPlex", ["CoreModels", "FeatureHome"]),
                     _target("FeatureHome", ["CoreModels"])]},
        True,
    ))
    # Rule 2: Service -> Feature.
    cases.append((
        "service->feature",
        {"targets": [_target("CoreModels"),
                     _target("TraktService", ["CoreModels", "FeatureHome"]),
                     _target("FeatureHome", ["CoreModels"])]},
        True,
    ))
    # Rule 3: CoreModels not a leaf.
    cases.append((
        "coremodels-not-leaf",
        {"targets": [_target("CoreModels", ["CoreNetworking"]),
                     _target("CoreNetworking")]},
        True,
    ))
    # Rule 4: vendor leak.
    cases.append((
        "vendor-leak",
        {"targets": [_target("CoreModels"),
                     _target("FeatureHome", ["CoreModels"], ["Sentry"])]},
        True,
    ))
    # Rule 5: cycle.
    cases.append((
        "cycle",
        {"targets": [_target("A", ["B"]), _target("B", ["A"])]},
        True,
    ))

    ok = True
    for name, manifest, expect_violation in cases:
        # Skip import-scan in self-test (no Sources tree) by pointing at nothing.
        violations = check_manifest(Package(manifest)) + check_acyclic(Package(manifest))
        got = bool(violations)
        status = "PASS" if got == expect_violation else "FAIL"
        if status == "FAIL":
            ok = False
        print(f"  {status}  {name}: expected_violation={expect_violation} "
              f"got={got}" + (f" ({violations})" if status == "FAIL" else ""))
    print("arch-guard --self-test: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


# --- CLI ---------------------------------------------------------------------

def main(argv: list[str]) -> int:
    args = argv[1:]
    if args and args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if args and args[0] == "--self-test":
        return _self_test()

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    sources_root = os.path.join(repo_root, "Sources")

    manifest = _dump_package()
    pkg = Package(manifest)
    violations = run_checks(manifest, sources_root)

    if violations:
        print("── architecture layering guard: VIOLATIONS ───────────", file=sys.stderr)
        for msg in violations:
            print(f"  ✗ {msg}", file=sys.stderr)
        print(f"  => {len(violations)} violation(s). See tools/arch-guard.py for the rules.",
              file=sys.stderr)
        print("──────────────────────────────────────────────────────", file=sys.stderr)
        return 1

    print(f"ARCH GUARD: OK ({len(pkg.names)} targets, layering intact)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
