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
  6. Observable member classification: every `@Observable` type's stored members
     are split into tracked-mutable / observation-ignored / stable-let-refs, plus
     its max init-arity. ONLY the tracked-mutable count (stored `var`, not
     @ObservationIgnored/computed/static — the real per-view type-check surface) is
     ENFORCED, against a decreasing-only allowlist. Stable `let` collaborator refs,
     @ObservationIgnored members, and wide initializers are reported informationally
     (a `let` is genuinely unobserved, so it's not harmful mutable surface). See the
     "Observable member classification policy" section below.

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
    # FeatureShareOnboarding is a shared media-share onboarding lib used by BOTH
    # the tvOS and iOS shells; it needs FeatureAuthCore's credential/fingerprint
    # types (SHA256Fingerprint, the media-share credential envelope). This code
    # previously lived in AppShell (allowed), and was extracted so iOS could
    # reuse it — a deliberate, reviewed relaxation.
    ("FeatureShareOnboarding", "FeatureAuthCore"),
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

# --- Observable member classification policy --------------------------------
# Earlier this guard counted ALL stored members (var+let) as one "fan-out" number.
# That conflated three very different things and pressured cosmetic extractions. A
# Swift `let` on an `@Observable` type is genuinely UNOBSERVED — the macro emits no
# tracked getter/setter/registrar for it — so a stable collaborator `let` is NOT
# harmful mutable-observable surface. `@ObservationIgnored` members aren't tracked
# either. The real per-view type-check risk is the count of TRACKED-MUTABLE props.
#
# So each `@Observable` type's stored members are classified into four buckets and
# reported distinctly (see `classify_observable_members`):
#   1. tracked-mutable  = stored `var`, NOT @ObservationIgnored, NOT computed, NOT
#      static/class. THE enforced category — the real observable surface a SwiftUI
#      view body type-checks against. Ceiling + decreasing-only allowlist apply
#      HERE ONLY.
#   2. observation-ignored = stored props (var or let) marked @ObservationIgnored.
#      Not tracked; reported informationally.
#   3. stable-let-refs  = stored `let` (collaborator/service references). Not
#      observable state; reported informationally (a large count is a mild
#      service-locator smell, not a CI failure).
#   4. init-arity       = max parameter count across the type's initializer(s).
#      Reported informationally — this is the signal that surfaces wide inits (e.g.
#      MainTabView) as future targets; it does NOT gate CI.
# Comments/blank lines are never counted (source is lexed first).

# Enforced ceiling for the TRACKED-MUTABLE count on any `@Observable` type.
# Rationale: 20 tracked-mutable observed vars is already "this type is doing too
# much"; healthy single-responsibility facets sit well below it. Types that exceed
# it get a DECREASING-only allowlist entry below.
TRACKED_MUTABLE_DEFAULT_MAX = 20

# Debt markers for the ENFORCED (tracked-mutable) category. Each entry is a
# ratchet: the guard FAILS if a type's tracked-mutable count EXCEEDS its budget, so
# the number may only ever be LOWERED as the type is decomposed. Raising an entry
# (or adding a new one) is a conscious, reviewed regression.
#
# These are the TRUE tracked-mutable counts (re-baselined after the AppState
# decomposition + the classifier fix). AppState finished at 7 real mutable vars —
# its 16 stable-let collaborator refs and 7 @ObservationIgnored members are NOT
# counted here (they're reported informationally). The pre-existing god objects are
# seeded at their real mutable-var counts, which is the point: it reveals the
# genuine mutable surface (e.g. ItemDetailViewModel was "37" under the old
# all-stored metric but is 23 tracked-mutable; PlayerControlsModel is a true 62).
TRACKED_MUTABLE_ALLOWLIST = {
    # The decomposed composition root — locked at its irreducible mutable core.
    "AppState": 7,
    # Pre-existing god objects, seeded at their TRUE tracked-mutable counts as debt
    # markers. Lower these as each is split; never raise them.
    "PlayerControlsModel": 62,
    "AudioPlaybackController": 42,
    "UnifiedAddShareModel": 36,
    "PlayerViewModel": 28,
    "ItemDetailViewModel": 23,
}

# Soft, INFORMATIONAL thresholds (never fail CI) — used only to surface smells in
# the guard's OK output so they can be picked up as future work.
STABLE_LET_REFS_SOFT_MAX = 18   # a larger `let`-ref count hints at a service locator
INIT_ARITY_SOFT_MAX = 12        # a wider initializer hints at a wide-injection target


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
# Peels a single leading attribute (`@Foo` or `@Foo(...)`) off the start of a line
# so inline-attributed declarations (`@ObservationIgnored var x`, `@Wrapper var y`)
# are classified correctly rather than skipped by the stored-prop matcher.
_LEADING_ATTR_RE = re.compile(r"^\s*(@[A-Za-z_]\w*(?:\([^)]*\))?)\s*")
# A type declaration whose inheritance clause conforms to SwiftUI `View` — used to
# scope the init-arity smell to injection-shaped types (Views + @Observable models)
# instead of flooding on data-model memberwise initializers.
_VIEW_CONFORMANCE_RE = re.compile(
    r"\b(?:class|struct|actor|enum)\s+[A-Za-z_]\w*\s*(?:<[^>]*>)?\s*:[^{]*\bView\b"
)
# An initializer declaration opening its parameter list.
_INIT_DECL_RE = re.compile(
    r"^(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|package\s+|"
    r"convenience\s+|required\s+|@\w+(?:\([^)]*\))?\s+)*init\s*[?!]?\s*(?:<[^>]*>)?\s*\("
)
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


def is_paired_feature_core(owner: str, dependency: str) -> bool:
    return dependency == f"{owner}Core"


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
                if (
                    (name, dep) not in ALLOWED_FEATURE_EDGES
                    and not is_paired_feature_core(name, dep)
                ):
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
                        if (
                            (target, mod) not in ALLOWED_FEATURE_EDGES
                            and not is_paired_feature_core(target, mod)
                        ):
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


def _peel_leading_attrs(line: str):
    """Peel leading `@Attr`/`@Attr(...)` tokens off a declaration line so inline-
    attributed props are classified, not skipped. Returns (attrs, remainder)."""
    attrs = []
    while True:
        m = _LEADING_ATTR_RE.match(line)
        if not m:
            break
        attrs.append(m.group(1))
        line = line[m.end():]
    return attrs, line


def _count_init_params(param_text: str) -> int:
    """Count parameters in an initializer's `( ... )` body by splitting on
    top-level commas (ignoring commas nested in (), [], {}, <>)."""
    depth = 0
    params = 0
    saw_token = False
    pairs = {"(": 1, ")": -1, "[": 1, "]": -1, "{": 1, "}": -1, "<": 1, ">": -1}
    for ch in param_text:
        depth += pairs.get(ch, 0)
        if not ch.isspace():
            saw_token = True
        if ch == "," and depth == 0:
            params += 1
    return (params + 1) if saw_token else 0


def _empty_buckets(name: str) -> dict:
    return {
        "name": name,
        "observable": False,
        "is_struct": False,
        "conforms_view": False,
        "tracked_mutable": 0,
        "observation_ignored": 0,
        "stable_let_refs": 0,
        "stored_props_total": 0,   # memberwise-init proxy for structs
        "init_arity": 0,
    }


def classify_observable_members(text: str) -> dict[str, dict]:
    """Scan one Swift file and classify each type's stored members.

    For every `@Observable` type the stored members are split into three buckets
    (tracked-mutable / observation-ignored / stable-let-refs). Init-arity (the max
    initializer parameter count) is tracked for ALL types — observable or not — so
    wide-injection targets like a big SwiftUI `View` (e.g. MainTabView) are surfaced
    too. Returns `{type_name: buckets}` (buckets carry an `observable` flag).

    Properties inside nested types or functions are attributed to their own
    immediate scope, never the outer type. Comments and string literals are
    neutralised first so they can never be miscounted. Inline-attributed and
    prior-line-attributed declarations are both handled.
    """
    lines = _strip_comments_and_strings(text.split("\n"))
    depth = 0
    stack: list[dict] = []          # type scopes: {..buckets.., "observable", "body_depth"}
    result: dict[str, dict] = {}
    recent_attrs: list[str] = []    # attribute-only lines seen since the last code line
    pending_init = None             # (entry, accumulated_param_text, paren_depth)

    for raw in lines:
        # --- continue accumulating a multi-line initializer parameter list ---
        if pending_init is not None:
            entry, buf, pdepth = pending_init
            buf += " " + raw
            pdepth += raw.count("(") - raw.count(")")
            if pdepth <= 0:
                inner = buf[buf.find("(") + 1: buf.rfind(")")]
                entry["init_arity"] = max(entry["init_arity"], _count_init_params(inner))
                pending_init = None
            else:
                pending_init = (entry, buf, pdepth)
            depth += raw.count("{") - raw.count("}")
            while stack and depth < stack[-1]["body_depth"]:
                _merge_bucket(result, stack.pop())
            continue

        line = raw.strip()
        if not line:
            continue

        # Accumulate attribute-only lines for the NEXT declaration.
        attrs_here = list(recent_attrs)
        if line.startswith("@") and not _TYPE_DECL_RE.search(line):
            inline_attrs, rest = _peel_leading_attrs(line)
            # A line that is ONLY attributes contributes nothing else this pass.
            if not rest.strip() and "{" not in line and "}" not in line:
                recent_attrs.extend(inline_attrs)
                continue

        # Peel any inline leading attributes off the declaration itself.
        inline_attrs, body = _peel_leading_attrs(line)
        attr_text = " ".join(attrs_here + inline_attrs)

        cur_depth = depth
        directly_in = stack[-1] if stack and stack[-1]["body_depth"] == cur_depth else None

        prop_m = _STORED_PROP_RE.match(body)
        type_m = _TYPE_DECL_RE.search(body)

        # Stored property directly inside a type body.
        if prop_m and not type_m and not _STATIC_PROP_RE.match(body):
            if directly_in and not _is_computed(body):
                # Memberwise-init proxy: count every stored prop for ANY type.
                directly_in["stored_props_total"] += 1
                if directly_in["observable"]:
                    is_let = re.search(r"\blet\s+" + re.escape(prop_m.group(1)) + r"\b", body) is not None
                    if _OBSERVATION_IGNORED_RE.search(attr_text):
                        directly_in["observation_ignored"] += 1
                    elif is_let:
                        directly_in["stable_let_refs"] += 1
                    else:
                        directly_in["tracked_mutable"] += 1

        # Initializer directly inside ANY type body → init-arity (all types).
        if directly_in and _INIT_DECL_RE.match(body):
            pdepth = raw.count("(") - raw.count(")")
            if pdepth <= 0:
                inner = body[body.find("(") + 1: body.rfind(")")]
                directly_in["init_arity"] = max(directly_in["init_arity"], _count_init_params(inner))
            else:
                pending_init = (directly_in, raw, pdepth)

        # Type declaration opening a body on this line?
        if type_m and "{" in body:
            name = type_m.group(2)
            observable = bool(_OBSERVABLE_ATTR_RE.search(attr_text)) and type_m.group(1) != "extension"
            entry = _empty_buckets(name)
            entry["observable"] = observable
            entry["is_struct"] = type_m.group(1) == "struct"
            entry["conforms_view"] = bool(_VIEW_CONFORMANCE_RE.search(body))
            entry["body_depth"] = cur_depth + 1
            stack.append(entry)

        recent_attrs = []

        # --- update brace depth and pop finished scopes ---
        if pending_init is None:
            for ch in raw:
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    while stack and depth < stack[-1]["body_depth"]:
                        _merge_bucket(result, stack.pop())

    while stack:
        _merge_bucket(result, stack.pop())
    return result


def _merge_bucket(result: dict, entry: dict) -> None:
    """Merge a finished type scope into the file-level result (max per bucket, so a
    type split across `extension`s or seen twice keeps its largest reading)."""
    cur = result.setdefault(entry["name"], _empty_buckets(entry["name"]))
    cur["observable"] = cur["observable"] or entry["observable"]
    cur["is_struct"] = cur["is_struct"] or entry["is_struct"]
    cur["conforms_view"] = cur["conforms_view"] or entry["conforms_view"]
    for k in ("tracked_mutable", "observation_ignored", "stable_let_refs",
              "stored_props_total", "init_arity"):
        cur[k] = max(cur[k], entry[k])


def _effective_init_arity(buckets: dict) -> int:
    """The widest way to construct the type: an explicit `init(...)`, or — for a
    struct with no wider explicit init — its implicit memberwise initializer (one
    parameter per stored property). This is what surfaces a big SwiftUI `View` like
    MainTabView, which takes ~35 members via the compiler-synthesised memberwise init."""
    memberwise = buckets["stored_props_total"] if buckets["is_struct"] else 0
    return max(buckets["init_arity"], memberwise)


def aggregate_classification(sources_root: str) -> dict[str, dict]:
    """Classify every type across Sources/**/*.swift, merged (max per bucket) across
    files. Observable types carry their member buckets; all types carry init-arity."""
    agg: dict[str, dict] = {}
    if not os.path.isdir(sources_root):
        return agg
    for dirpath, _dirs, files in os.walk(sources_root):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8") as fh:
                    text = fh.read()
            except (OSError, UnicodeDecodeError):
                continue
            for name, buckets in classify_observable_members(text).items():
                _merge_bucket(agg, buckets)
    return agg


def check_tracked_mutable_fanout(sources_root: str) -> list[str]:
    """Enforce the TRACKED-MUTABLE ceiling (the only enforced observable category).

    A type's tracked-mutable count must not exceed `TRACKED_MUTABLE_ALLOWLIST[type]`
    if listed, otherwise `TRACKED_MUTABLE_DEFAULT_MAX`. Stable-let refs,
    @ObservationIgnored members, and init-arity are NOT enforced here (informational
    only). Allowlist entries are a decreasing-only ratchet.
    """
    v: list[str] = []
    agg = aggregate_classification(sources_root)
    for name in sorted(agg):
        if not agg[name]["observable"]:
            continue  # tracked-mutable is only meaningful for @Observable types
        count = agg[name]["tracked_mutable"]
        budget = TRACKED_MUTABLE_ALLOWLIST.get(name, TRACKED_MUTABLE_DEFAULT_MAX)
        if count > budget:
            if name in TRACKED_MUTABLE_ALLOWLIST:
                v.append(
                    f"[fanout] @Observable type '{name}' has {count} tracked-mutable "
                    f"properties, exceeding its allowlisted budget of {budget}. The "
                    f"allowlist is a DECREASING-only ratchet — extract a facet to "
                    f"shrink it, don't raise the number."
                )
            else:
                v.append(
                    f"[fanout] @Observable type '{name}' has {count} tracked-mutable "
                    f"properties, exceeding the ceiling of {TRACKED_MUTABLE_DEFAULT_MAX}. "
                    f"Split it into narrower single-responsibility facets, or add a "
                    f"DECREASING-only TRACKED_MUTABLE_ALLOWLIST entry if this is tracked debt."
                )
    return v


def observable_fanout_report(sources_root: str) -> list[str]:
    """Non-failing informational lines: tracked-mutable ratchet-tighten hints, plus
    stable-let-ref and init-arity smells surfaced for future work."""
    out: list[str] = []
    agg = aggregate_classification(sources_root)
    # Tighten hints for the enforced category.
    for name, budget in TRACKED_MUTABLE_ALLOWLIST.items():
        count = agg.get(name, _empty_buckets(name))["tracked_mutable"]
        if count < budget:
            out.append(
                f"tracked-mutable ratchet: TRACKED_MUTABLE_ALLOWLIST['{name}'] can "
                f"tighten {budget} -> {count} (now under budget)."
            )
    # Informational smells (never fail): wide stable-let refs (observable types
    # only — a service-locator smell) / wide initializers. The init-arity smell is
    # scoped to INJECTION-shaped types — @Observable models or SwiftUI `View`s — so
    # it surfaces wide-injection targets (e.g. MainTabView's ~35-member memberwise
    # init) instead of flooding on data-model value types' memberwise inits.
    for name in sorted(agg):
        b = agg[name]
        if b["observable"] and b["stable_let_refs"] > STABLE_LET_REFS_SOFT_MAX:
            out.append(
                f"stable-let-refs smell: '{name}' holds {b['stable_let_refs']} `let` "
                f"collaborator refs (> {STABLE_LET_REFS_SOFT_MAX}); consider whether "
                f"it's becoming a service locator (informational, not enforced)."
            )
        if b["observable"] or b["conforms_view"]:
            arity = _effective_init_arity(b)
            if arity > INIT_ARITY_SOFT_MAX:
                kind = "memberwise" if arity == b["stored_props_total"] and arity > b["init_arity"] else "explicit"
                article = "an" if kind == "explicit" else "a"
                out.append(
                    f"init-arity smell: '{name}' has {article} {kind} initializer with {arity} "
                    f"parameters (> {INIT_ARITY_SOFT_MAX}); a wide-injection target "
                    f"(informational, not enforced)."
                )
    return out



def run_checks(manifest: dict, sources_root: str) -> list[str]:
    pkg = Package(manifest)
    violations: list[str] = []
    violations += check_manifest(pkg)
    violations += check_acyclic(pkg)
    violations += check_imports(pkg, sources_root)
    violations += check_tracked_mutable_fanout(sources_root)
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
    """Fixture set for the multi-category observable classifier + tracked-mutable
    enforcement. A regex classifier can silently lie, so these pin every bucket."""
    ok = True

    def check(label, cond):
        nonlocal ok
        status = "PASS" if cond else "FAIL"
        if not cond:
            ok = False
        print(f"  {status}  fanout:{label}")

    def buckets(src, tname):
        return classify_observable_members(src).get(tname)

    def vars_(n):
        return "\n".join(f"    var p{i}: Int = 0" for i in range(n))

    # --- classification: each bucket pinned distinctly ---
    b = buckets("@Observable final class A {\n" + vars_(3) + "\n}", "A")
    check("basic-tracked=3", b and b["tracked_mutable"] == 3 and b["stable_let_refs"] == 0)

    # Stored `let` refs are NOT tracked-mutable (the whole point of this refactor).
    b = buckets("@Observable class A {\n    let a = X()\n    let b = Y()\n    var x = 0\n}", "A")
    check("stored-let-not-tracked",
          b and b["tracked_mutable"] == 1 and b["stable_let_refs"] == 2)

    # Computed excluded; stored closure-init stays tracked.
    b = buckets("@Observable class A {\n    var stored = 0\n    var comp: Int { 1 }\n"
                "    var closure = { 1 }()\n}", "A")
    check("computed-excluded", b and b["tracked_mutable"] == 2)

    # @ObservationIgnored var — attr on the line above — excluded from tracked.
    b = buckets("@Observable class A {\n    var x = 0\n    @ObservationIgnored\n    var y = 0\n}", "A")
    check("ignored-var-above",
          b and b["tracked_mutable"] == 1 and b["observation_ignored"] == 1)

    # @ObservationIgnored var — inline on the same line — excluded from tracked.
    b = buckets("@Observable class A {\n    var x = 0\n    @ObservationIgnored var y = 0\n}", "A")
    check("ignored-var-inline",
          b and b["tracked_mutable"] == 1 and b["observation_ignored"] == 1)

    # @ObservationIgnored let — counts as observation-ignored, not stable-let.
    b = buckets("@Observable class A {\n    @ObservationIgnored let z = X()\n    var x = 0\n}", "A")
    check("ignored-let",
          b and b["tracked_mutable"] == 1 and b["observation_ignored"] == 1 and b["stable_let_refs"] == 0)

    # A non-observation property wrapper on a stored var → still tracked-mutable.
    b = buckets("@Observable class A {\n    @Wrapper var x = 0\n}", "A")
    check("property-wrapper-tracked", b and b["tracked_mutable"] == 1)

    # static / class type-level members excluded from every bucket.
    b = buckets("@Observable class A {\n    var x = 0\n    static var s = 0\n"
                "    static let sl = 0\n    class var c: Int { 0 }\n}", "A")
    check("static-excluded",
          b and b["tracked_mutable"] == 1 and b["stable_let_refs"] == 0)

    # Nested type's props are attributed to the nested type, not the outer one.
    b = buckets("@Observable class A {\n    var x = 0\n    struct Inner {\n        var a = 0\n"
                "        var bb = 0\n    }\n    var y = 0\n}", "A")
    check("nested-not-counted", b and b["tracked_mutable"] == 2)

    # Function-local vars are not counted.
    b = buckets("@Observable class A {\n    var x = 0\n    func f() {\n        var local = 0\n"
                "        _ = local\n    }\n}", "A")
    check("func-locals-excluded", b and b["tracked_mutable"] == 1)

    # Multiline stored property (initializer spanning lines) counts once.
    b = buckets("@Observable class A {\n    var x = Foo(\n        a: 1,\n        b: 2\n    )\n    var y = 0\n}", "A")
    check("multiline-prop", b and b["tracked_mutable"] == 2)

    # Conditional-compilation around props: both counted, #if/#endif ignored.
    b = buckets("@Observable class A {\n    #if canImport(UIKit)\n    var a = 0\n    #endif\n    var b = 0\n}", "A")
    check("cond-compilation", b and b["tracked_mutable"] == 2)

    # Multiple decorators before the type still detected as @Observable.
    b = buckets("@MainActor\n@Observable\nfinal class A {\n" + vars_(4) + "\n}", "A")
    check("multi-attr-type", b and b["tracked_mutable"] == 4)

    # init-arity: single-line initializer.
    b = buckets("@Observable class A {\n    var x = 0\n    init(a: Int, b: Int, c: Int) {}\n}", "A")
    check("init-arity-single", b and b["init_arity"] == 3)

    # init-arity: multiline initializer, with nested commas that must NOT inflate.
    b = buckets("@Observable class A {\n    init(\n        a: Int,\n        b: (Int, Int),\n"
                "        c: [String: Int] = [:]\n    ) {}\n}", "A")
    check("init-arity-multiline", b and b["init_arity"] == 3)

    # init-arity: zero-arg init.
    b = buckets("@Observable class A {\n    var x = 0\n    init() {}\n}", "A")
    check("init-arity-zero", b and b["init_arity"] == 0)

    # Non-@Observable type: members are NOT bucketed (tracked-mutable stays 0), but
    # the type may still be present for init-arity purposes.
    got = classify_observable_members("final class Plain {\n" + vars_(40) + "\n}")
    check("non-observable-not-bucketed",
          got.get("Plain", {}).get("tracked_mutable", 0) == 0
          and got.get("Plain", {}).get("observable") is False)

    # Init-arity is tracked for NON-@Observable types too (surfaces wide Views like
    # MainTabView). A View struct with a wide init is measured, not bucketed.
    got = classify_observable_members(
        "struct BigView: View {\n    init(a: Int, b: Int, c: Int, d: Int) {}\n}")
    bv = got.get("BigView", {})
    check("non-observable-init-arity",
          bv.get("init_arity") == 4 and bv.get("observable") is False
          and bv.get("tracked_mutable") == 0)

    # --- enforcement: tracked-mutable ceiling + decreasing ratchet ---
    import tempfile

    def write_tree(files):
        d = tempfile.mkdtemp()
        for rel, content in files.items():
            fp = os.path.join(d, rel)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            with open(fp, "w") as fh:
                fh.write(content)
        return d

    saved = dict(TRACKED_MUTABLE_ALLOWLIST)
    try:
        # Under ceiling (10 tracked vars) → pass.
        d = write_tree({"M/A.swift": "@Observable class Small {\n" + vars_(10) + "\n}"})
        check("under-ceiling", not check_tracked_mutable_fanout(d))

        # Over ceiling, unlisted (25 tracked vars) → fail.
        TRACKED_MUTABLE_ALLOWLIST.clear(); TRACKED_MUTABLE_ALLOWLIST.update(saved)
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + vars_(25) + "\n}"})
        check("over-ceiling-unlisted", bool(check_tracked_mutable_fanout(d)))

        # Over ceiling but within allowlist → pass.
        TRACKED_MUTABLE_ALLOWLIST.clear(); TRACKED_MUTABLE_ALLOWLIST["Big"] = 25
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + vars_(25) + "\n}"})
        check("over-ceiling-within-allowlist", not check_tracked_mutable_fanout(d))

        # Allowlisted but EXCEEDS its (too-low) budget → fail (ratchet enforced).
        TRACKED_MUTABLE_ALLOWLIST.clear(); TRACKED_MUTABLE_ALLOWLIST["Big"] = 20
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + vars_(25) + "\n}"})
        check("allowlist-exceeded", bool(check_tracked_mutable_fanout(d)))

        # Allowlisted and now UNDER budget → pass + tighten hint offered.
        TRACKED_MUTABLE_ALLOWLIST.clear(); TRACKED_MUTABLE_ALLOWLIST["Big"] = 25
        d = write_tree({"M/B.swift": "@Observable class Big {\n" + vars_(12) + "\n}"})
        no_viol = not check_tracked_mutable_fanout(d)
        has_hint = any("Big" in h for h in observable_fanout_report(d))
        check("under-allowlist-hint", no_viol and has_hint)

        # Stable-let refs alone do NOT fail CI (only surface a smell).
        TRACKED_MUTABLE_ALLOWLIST.clear()
        lets = "\n".join(f"    let r{i} = X()" for i in range(30))
        d = write_tree({"M/C.swift": "@Observable class Locator {\n" + lets + "\n}"})
        no_viol = not check_tracked_mutable_fanout(d)
        has_smell = any("stable-let-refs smell" in h and "Locator" in h
                        for h in observable_fanout_report(d))
        check("stable-let-no-fail-but-smell", no_viol and has_smell)

        # Wide init alone does NOT fail CI (only surface a smell).
        TRACKED_MUTABLE_ALLOWLIST.clear()
        params = ", ".join(f"a{i}: Int" for i in range(15))
        d = write_tree({"M/D.swift": "@Observable class Wide {\n    var x = 0\n"
                                     f"    init({params}) {{}}\n}}"})
        no_viol = not check_tracked_mutable_fanout(d)
        has_smell = any("init-arity smell" in h and "Wide" in h
                        for h in observable_fanout_report(d))
        check("wide-init-no-fail-but-smell", no_viol and has_smell)

        # A big SwiftUI `View` with NO explicit init is surfaced via its implicit
        # MEMBERWISE initializer (one param per stored prop) — this is MainTabView.
        TRACKED_MUTABLE_ALLOWLIST.clear()
        members = "\n".join(f"    let m{i}: Int" for i in range(20))
        d = write_tree({"M/E.swift": "struct BigView: View {\n" + members + "\n    var body: some View { EmptyView() }\n}"})
        report = observable_fanout_report(d)
        has_memberwise = any("init-arity smell" in h and "BigView" in h and "memberwise" in h
                             for h in report)
        check("view-memberwise-init-surfaced",
              not check_tracked_mutable_fanout(d) and has_memberwise)

        # A DATA-MODEL value type with a wide memberwise init is NOT a wide-injection
        # smell (not @Observable, not a View) — must stay silent, killing the noise.
        TRACKED_MUTABLE_ALLOWLIST.clear()
        fields = "\n".join(f"    let f{i}: Int" for i in range(30))
        d = write_tree({"M/F.swift": "struct DataModel: Codable, Sendable {\n" + fields + "\n}"})
        report = observable_fanout_report(d)
        silent = not any("DataModel" in h for h in report)
        check("data-model-not-surfaced",
              not check_tracked_mutable_fanout(d) and silent)
    finally:
        TRACKED_MUTABLE_ALLOWLIST.clear(); TRACKED_MUTABLE_ALLOWLIST.update(saved)

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
    for line in observable_fanout_report(sources_root):
        print(f"  ℹ {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
