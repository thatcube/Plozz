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

# --- Observable fan-out policy ----------------------------------------------
# The metric that actually hurt us: the number of STORED OBSERVABLE properties on
# a single `@Observable` type (its "fan-out"). A wide observable surface makes
# every SwiftUI view that touches `thatType.*` pay a large Swift type-check tax
# (AppState's ~59-property surface regressed FirstRunProfileView/RootView by
# ~230ms/view). This is NOT raw line count and NOT comments/blank lines — it is
# specifically the count of type-body-scope `var`/`let` that are observed:
#   - EXCLUDING `static` (not per-instance observable state),
#   - EXCLUDING `@ObservationIgnored` (opted out of tracking),
#   - EXCLUDING computed properties (a `{ ... }` accessor block with no
#     initializer — they store nothing and don't participate in observation).
#
# Default ceiling for any `@Observable` type. Rationale: bounds the member
# surface a view body must type-infer against; healthy single-responsibility
# facets sit comfortably below this. Types that legitimately exceed it (mid-
# decomposition god objects) get a DECREASING-only allowlist entry below.
OBSERVABLE_FANOUT_DEFAULT_MAX = 25

# Debt markers for types still above the default ceiling. Each entry is a
# ratchet: the guard FAILS if a type's actual fan-out EXCEEDS its allowlisted
# budget, so the number may only ever be LOWERED as the type is decomposed.
# Raising an entry (or adding a new one) is a conscious, reviewed regression.
# AppState is being decomposed into single-responsibility facets; this budget
# tracks that shrink (was 62 before the ProfileSettingsModel extraction).
OBSERVABLE_FANOUT_ALLOWLIST = {
    # Being actively decomposed into single-responsibility facets (this workstream).
    "AppState": 29,               # 62->44 (ProfileSettings)->39 (IdentityIndex)->36 (AccountsProviders)->29 (PlexHomeUsers).
    # Pre-existing god objects seeded at their current fan-out as debt markers so
    # the ratchet prevents REGRESSION today and flags them as future decomposition
    # targets. Lower these as each is split; never raise them.
    "PlayerControlsModel": 62,
    "PlayerViewModel": 50,
    "UnifiedAddShareModel": 43,
    "AudioPlaybackController": 43,
    "ItemDetailViewModel": 37,
}

# Matches a stored-property declaration at a type body scope, capturing the name.
# Deliberately excludes `static`/`class` type-level members via the negative set.
_STORED_PROP_RE = re.compile(
    r"^(?:public|private|internal|fileprivate|open|package)?\s*"
    r"(?:public\(set\)|private\(set\)|internal\(set\)|fileprivate\(set\))?\s*"
    r"(?:weak\s+|unowned\s+|lazy\s+)?"
    r"(?:var|let)\s+([A-Za-z_]\w*)\s*(?::|=)"
)
_STATIC_PROP_RE = re.compile(
    r"^(?:public|private|internal|fileprivate|open|package)?\s*"
    r"(?:static|class)\s+(?:var|let)\b"
)
_OBSERVABLE_ATTR_RE = re.compile(r"@Observable\b")
_OBSERVATION_IGNORED_RE = re.compile(r"@ObservationIgnored\b")
# Type declarations that open a new brace scope we must track for nesting.
_TYPE_DECL_RE = re.compile(
    r"\b(?:final\s+)?(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|package\s+)*"
    r"(?:final\s+)?(class|struct|actor|enum|extension)\s+([A-Za-z_]\w*)"
)

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


def _is_computed(decl_line: str) -> bool:
    """A stored property has an initializer/type-only decl; a computed property is
    a `{ ... }` accessor block with NO initializer. Heuristic: there's a `{` and no
    `=` precedes it (so `var x = { ... }()` — a stored closure init — stays stored).
    """
    if "{" not in decl_line:
        return False
    return "=" not in decl_line.split("{", 1)[0]


def count_observable_fanout(text: str) -> list[tuple[str, int]]:
    """Scan one Swift file and return `(type_name, stored_observable_prop_count)`
    for every `@Observable` type DECLARED in it.

    Fan-out counts type-body-scope stored `var`/`let` that are NOT `static`/`class`,
    NOT `@ObservationIgnored`, and NOT computed. Properties inside nested types or
    functions are attributed to their own immediate scope, never the outer type, so
    a nested helper type can't inflate an outer `@Observable`'s count. Comments and
    string literals are neutralised first so they can never be miscounted.
    """
    lines = _strip_comments_and_strings(text.split("\n"))
    depth = 0
    # scope stack entries: {"name", "observable", "body_depth"}
    stack: list[dict] = []
    counts: dict[str, int] = {}
    order: list[str] = []
    recent_attrs: list[str] = []  # attributes seen since the last code line

    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        # Attributes decorating the NEXT declaration may sit on their own lines.
        attrs_here = list(recent_attrs)
        if line.startswith("@"):
            recent_attrs.append(line)
            # A line that is ONLY attributes contributes nothing else this pass.
            if line.lstrip().split(None, 1)[0].startswith("@") and not _TYPE_DECL_RE.search(line) \
               and not _STORED_PROP_RE.match(line):
                # keep accumulating unless the same line also holds a decl
                if "{" not in line and "}" not in line:
                    continue

        # Effective attribute text for a decl on THIS line = accumulated + inline.
        attr_text = " ".join(attrs_here) + " " + line

        # --- classify this line before counting its braces ---
        cur_depth = depth
        directly_in = stack[-1] if stack and stack[-1]["body_depth"] == cur_depth else None

        # Property? (only counts when directly inside an @Observable type body)
        prop_m = _STORED_PROP_RE.match(line)
        type_m = _TYPE_DECL_RE.search(line)
        if prop_m and not type_m and not _STATIC_PROP_RE.match(line):
            if directly_in and directly_in["observable"]:
                if not _OBSERVATION_IGNORED_RE.search(attr_text) and not _is_computed(line):
                    directly_in["count"] += 1

        # Type declaration opening a body on this line?
        if type_m and "{" in line:
            name = type_m.group(2)
            observable = bool(_OBSERVABLE_ATTR_RE.search(attr_text))
            kind = type_m.group(1)
            entry = {
                "name": name,
                "observable": observable and kind != "extension",
                "body_depth": cur_depth + 1,
                "count": 0,
            }
            stack.append(entry)
            if entry["observable"] and name not in counts:
                order.append(name)

        # Any non-blank line resets the pending-attribute accumulator.
        recent_attrs = []

        # --- update brace depth and pop finished scopes ---
        for ch in raw:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                # Pop any scope whose body we've now closed.
                while stack and depth < stack[-1]["body_depth"]:
                    done = stack.pop()
                    if done["observable"]:
                        counts[done["name"]] = counts.get(done["name"], 0) + done["count"]

    # Close any still-open observable scopes (malformed input tolerance).
    while stack:
        done = stack.pop()
        if done["observable"]:
            counts[done["name"]] = counts.get(done["name"], 0) + done["count"]

    return [(n, counts[n]) for n in order]


def check_observable_fanout(sources_root: str) -> list[str]:
    """Enforce the observable-fan-out ceiling across Sources/**/*.swift.

    A type's fan-out must not exceed `OBSERVABLE_FANOUT_ALLOWLIST[type]` if listed,
    otherwise `OBSERVABLE_FANOUT_DEFAULT_MAX`. Allowlist entries are debt markers
    that may only shrink; a listed type now UNDER its budget is reported as a hint
    (not a failure) so the ratchet can be tightened.
    """
    v: list[str] = []
    if not os.path.isdir(sources_root):
        return v
    totals: dict[str, int] = {}
    for dirpath, _dirs, files in os.walk(sources_root):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                with open(path, encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                continue
            for name, count in count_observable_fanout(text):
                totals[name] = max(totals.get(name, 0), count)

    for name in sorted(totals):
        count = totals[name]
        budget = OBSERVABLE_FANOUT_ALLOWLIST.get(name, OBSERVABLE_FANOUT_DEFAULT_MAX)
        if count > budget:
            if name in OBSERVABLE_FANOUT_ALLOWLIST:
                v.append(
                    f"[fanout] @Observable type '{name}' has {count} stored "
                    f"observable properties, exceeding its allowlisted budget of "
                    f"{budget}. The allowlist is a DECREASING-only ratchet — extract "
                    f"a facet to shrink it, don't raise the number."
                )
            else:
                v.append(
                    f"[fanout] @Observable type '{name}' has {count} stored "
                    f"observable properties, exceeding the ceiling of "
                    f"{OBSERVABLE_FANOUT_DEFAULT_MAX}. Split it into narrower "
                    f"single-responsibility facets, or add a DECREASING-only "
                    f"OBSERVABLE_FANOUT_ALLOWLIST entry if this is tracked debt."
                )
    return v


def observable_fanout_hints(sources_root: str) -> list[str]:
    """Non-failing hints: allowlisted types now at/under their budget can tighten."""
    hints: list[str] = []
    if not os.path.isdir(sources_root):
        return hints
    totals: dict[str, int] = {}
    for dirpath, _dirs, files in os.walk(sources_root):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                continue
            for name, count in count_observable_fanout(text):
                totals[name] = max(totals.get(name, 0), count)
    for name, budget in OBSERVABLE_FANOUT_ALLOWLIST.items():
        count = totals.get(name, 0)
        if count < budget:
            hints.append(
                f"OBSERVABLE_FANOUT_ALLOWLIST['{name}'] can tighten {budget} -> "
                f"{count} (type is now under budget)."
            )
    return hints


def run_checks(manifest: dict, sources_root: str) -> list[str]:
    pkg = Package(manifest)
    violations: list[str] = []
    violations += check_manifest(pkg)
    violations += check_acyclic(pkg)
    violations += check_imports(pkg, sources_root)
    violations += check_observable_fanout(sources_root)
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

    if not _self_test_fanout():
        ok = False
    print("arch-guard --self-test: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


def _self_test_fanout() -> bool:
    """Fixture set for the observable-fan-out counter/checker."""
    ok = True

    def prop(n):
        return "\n".join(f"    var p{i}: Int = 0" for i in range(n))

    # (label, swift source, type_name, expected_count)
    count_cases: list[tuple[str, str, str, int]] = [
        # Basic stored count on an @Observable type.
        ("basic",
         "@Observable final class A {\n" + prop(3) + "\n}", "A", 3),
        # @ObservationIgnored excluded (attr on preceding line).
        ("ignored-excluded",
         "@Observable class A {\n    var x = 0\n    @ObservationIgnored\n    var y = 0\n}",
         "A", 1),
        # @ObservationIgnored inline on the same line excluded.
        ("ignored-inline",
         "@Observable class A {\n    var x = 0\n    @ObservationIgnored var y = 0\n}",
         "A", 1),
        # Computed properties excluded; stored closure-init NOT excluded.
        ("computed-excluded",
         "@Observable class A {\n    var stored = 0\n    var comp: Int { 1 }\n"
         "    var closure = { 1 }()\n}", "A", 2),
        # static/class type-level members excluded.
        ("static-excluded",
         "@Observable class A {\n    var x = 0\n    static var s = 0\n    class var c: Int { 0 }\n}",
         "A", 1),
        # Nested type's props not attributed to the outer @Observable type.
        ("nested-not-counted",
         "@Observable class A {\n    var x = 0\n    struct Inner {\n        var a = 0\n"
         "        var b = 0\n    }\n    var y = 0\n}", "A", 2),
        # Props inside a function body not counted.
        ("func-locals-excluded",
         "@Observable class A {\n    var x = 0\n    func f() {\n        var local = 0\n"
         "        _ = local\n    }\n}", "A", 1),
        # Multiple decorators before the type still detected as @Observable.
        ("multi-attr-type",
         "@MainActor\n@Observable\nfinal class A {\n" + prop(4) + "\n}", "A", 4),
    ]
    for label, src, tname, expected in count_cases:
        got = dict(count_observable_fanout(src)).get(tname)
        status = "PASS" if got == expected else "FAIL"
        if status == "FAIL":
            ok = False
        print(f"  {status}  fanout:{label}: expected={expected} got={got}")

    # Non-@Observable type must NOT be reported at all.
    plain = "final class Plain {\n" + prop(40) + "\n}"
    got_plain = dict(count_observable_fanout(plain))
    status = "PASS" if "Plain" not in got_plain else "FAIL"
    if status == "FAIL":
        ok = False
    print(f"  {status}  fanout:non-observable-ignored: reported={list(got_plain)}")

    # --- checker (threshold + allowlist ratchet) fixtures, via a temp tree ---
    import tempfile

    def write_tree(files: dict[str, str]):
        d = tempfile.mkdtemp()
        for rel, content in files.items():
            p = os.path.join(d, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
                fh.write(content)
        return d

    saved = dict(OBSERVABLE_FANOUT_ALLOWLIST)
    try:
        # under default ceiling -> pass
        d = write_tree({"M/A.swift": "@Observable class Small {\n" + prop(10) + "\n}"})
        r = check_observable_fanout(d)
        s = "PASS" if not r else "FAIL"; ok = ok and not r
        print(f"  {s}  fanout:under-ceiling: violations={r}")

        # over default ceiling, not allowlisted -> fail
        OBSERVABLE_FANOUT_ALLOWLIST.clear()
        OBSERVABLE_FANOUT_ALLOWLIST.update(saved)
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + prop(30) + "\n}"})
        r = check_observable_fanout(d)
        s = "PASS" if r else "FAIL"; ok = ok and bool(r)
        print(f"  {s}  fanout:over-ceiling-unlisted: violations={len(r)}")

        # over ceiling but within allowlist -> pass
        OBSERVABLE_FANOUT_ALLOWLIST.clear()
        OBSERVABLE_FANOUT_ALLOWLIST["Big"] = 30
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + prop(30) + "\n}"})
        r = check_observable_fanout(d)
        s = "PASS" if not r else "FAIL"; ok = ok and not r
        print(f"  {s}  fanout:over-ceiling-within-allowlist: violations={r}")

        # allowlisted but EXCEEDS its (too-low) budget -> fail (ratchet enforced)
        OBSERVABLE_FANOUT_ALLOWLIST.clear()
        OBSERVABLE_FANOUT_ALLOWLIST["Big"] = 20
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + prop(30) + "\n}"})
        r = check_observable_fanout(d)
        s = "PASS" if r else "FAIL"; ok = ok and bool(r)
        print(f"  {s}  fanout:allowlist-exceeded: violations={len(r)}")

        # allowlisted and now UNDER budget -> pass + tighten hint offered
        OBSERVABLE_FANOUT_ALLOWLIST.clear()
        OBSERVABLE_FANOUT_ALLOWLIST["Big"] = 30
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + prop(18) + "\n}"})
        r = check_observable_fanout(d)
        h = observable_fanout_hints(d)
        s = "PASS" if (not r and h) else "FAIL"; ok = ok and (not r and bool(h))
        print(f"  {s}  fanout:under-allowlist-hint: violations={r} hints={len(h)}")
    finally:
        OBSERVABLE_FANOUT_ALLOWLIST.clear()
        OBSERVABLE_FANOUT_ALLOWLIST.update(saved)

    return ok


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
    for hint in observable_fanout_hints(sources_root):
        print(f"  ℹ fan-out ratchet: {hint}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
