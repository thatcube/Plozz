#!/usr/bin/env python3
"""Validate isolated language files and merge them into Localizable.xcstrings.

Translation agents never edit the repository catalog. They write one JSON file
per language outside Git, then this tool is the only path into the catalog. That
keeps parallel agents from fighting over one 1.5 MB file and gives every
translation the same structural gate.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = REPO / "App/Resources/Localizable.xcstrings"
GUARD_CONFIG = REPO / "tools/l10n-guard.json"
INFO_CATALOGS = {
    "tvOS.NSLocalNetworkUsageDescription": (
        REPO / "App/Resources/InfoPlist.xcstrings",
        "NSLocalNetworkUsageDescription",
    ),
    "iOS.NSLocalNetworkUsageDescription": (
        REPO / "App/PlozziOS/InfoPlist.xcstrings",
        "NSLocalNetworkUsageDescription",
    ),
    "iOS.NSCameraUsageDescription": (
        REPO / "App/PlozziOS/InfoPlist.xcstrings",
        "NSCameraUsageDescription",
    ),
}

# Foundation format specifiers emitted by String Catalog extraction. The parser
# intentionally does not accept arbitrary printf syntax: an unknown specifier in
# a translation should fail loudly rather than survive until a user opens the
# affected screen.
FORMAT_RE = re.compile(
    r"%(?!%)(?:(?P<position>\d+)\$)?"
    r"(?:\.\d+)?"
    r"(?P<type>lld|llu|ld|lu|lf|d|u|f|@)"
)
SUBSTITUTION_RE = re.compile(r"%#@(?P<name>[A-Za-z0-9_]+)@")
SEMANTIC_KEY_RE = re.compile(r"^[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9_-]+)+$")
ALLOWED_STATES = {"new", "needs_review", "translated", "stale"}
LANGUAGE_TAG_RE = re.compile(
    r"^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|\d{3}))?$"
)


class ImportErrorDetail(Exception):
    """One language file is structurally unsafe to import."""


def never_translate_terms() -> list[str]:
    config = load_json(GUARD_CONFIG)
    terms = config.get("neverTranslate", [])
    if not isinstance(terms, list) or not all(
        isinstance(term, str) for term in terms
    ):
        raise ImportErrorDetail(
            f"{GUARD_CONFIG.relative_to(REPO)}: neverTranslate must be a string list"
        )
    return sorted(terms, key=len, reverse=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "input_dir",
        type=Path,
        help="Directory containing <language>.json files produced by translators.",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_CATALOG,
        help=f"Catalog to update (default: {DEFAULT_CATALOG.relative_to(REPO)}).",
    )
    parser.add_argument(
        "--languages",
        help="Comma-separated language tags. Defaults to every JSON except source.json.",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Write the validated translations. Without this, perform a dry run.",
    )
    parser.add_argument(
        "--allow-translated-state",
        action="store_true",
        help=(
            "Allow imported units marked translated. By default all agent output "
            "must remain needs_review so provenance stays honest."
        ),
    )
    parser.add_argument(
        "--require-info-plist",
        action="store_true",
        help=(
            "Require and import all tvOS/iOS permission-prompt translations from "
            "each language file's infoPlist object."
        ),
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ImportErrorDetail(f"missing file: {path}") from error
    except json.JSONDecodeError as error:
        raise ImportErrorDetail(
            f"{path.name}:{error.lineno}:{error.colno}: invalid JSON: {error.msg}"
        ) from error
    if not isinstance(value, dict):
        raise ImportErrorDetail(f"{path.name}: root must be an object")
    return value


def string_units(value: Any, path: str = "") -> list[tuple[str, dict[str, Any]]]:
    """Every String Catalog stringUnit recursively contained in *value*."""

    units: list[tuple[str, dict[str, Any]]] = []
    if isinstance(value, dict):
        unit = value.get("stringUnit")
        if isinstance(unit, dict):
            units.append((f"{path}.stringUnit", unit))
        for key, child in value.items():
            if key != "stringUnit":
                units.extend(string_units(child, f"{path}.{key}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            units.extend(string_units(child, f"{path}[{index}]"))
    return units


def placeholder_types(text: str) -> list[str]:
    return [match.group("type") for match in FORMAT_RE.finditer(text)]


def validate_known_format_syntax(text: str, context: str) -> None:
    """Reject a percent sequence the importer does not understand.

    The current catalog uses `%@`, `%lld`, positional variants, named plural
    substitutions, and literal `%%`. Silently ignoring any future printf form
    would make placeholder equality meaningless, so fail until the parser grows
    support deliberately.
    """

    consumed = [False] * len(text)
    for regex in (FORMAT_RE, SUBSTITUTION_RE, re.compile(r"%%")):
        for match in regex.finditer(text):
            for index in range(match.start(), match.end()):
                consumed[index] = True
    unknown = [
        index
        for index, character in enumerate(text)
        if character == "%" and not consumed[index]
    ]
    if unknown:
        sample = text[unknown[0] : unknown[0] + 12]
        raise ImportErrorDetail(
            f"{context}: unsupported format sequence starting {sample!r}"
        )


def source_text(key: str, entry: dict[str, Any]) -> str:
    english = entry.get("localizations", {}).get("en", {})
    direct = english.get("stringUnit", {}).get("value")
    return direct if isinstance(direct, str) else key


def expected_placeholder_types(key: str, entry: dict[str, Any]) -> Counter[str]:
    """Runtime arguments represented by the source key.

    The natural key is the compiler-emitted format string even when the English
    localization has plural substitutions. Semantic keys instead carry their
    default value in en.stringUnit.
    """

    text = source_text(key, entry) if SEMANTIC_KEY_RE.fullmatch(key) else key
    return Counter(placeholder_types(text))


def translated_placeholder_types(localization: dict[str, Any]) -> Counter[str]:
    """Runtime argument types represented by one translated localization.

    A plural substitution repeats its format specifier in every category, so
    recursively counting every leaf would over-count. Substitutions therefore
    contribute exactly once through their declared formatSpecifier. Remaining
    non-substitution arguments come from the top-level stringUnit.
    """

    result: Counter[str] = Counter()
    substitutions = localization.get("substitutions", {})
    if substitutions is not None and not isinstance(substitutions, dict):
        raise ImportErrorDetail("substitutions must be an object")

    substitution_names = set(substitutions or {})
    top_value = localization.get("stringUnit", {}).get("value", "")
    if isinstance(top_value, str):
        validate_known_format_syntax(top_value, "top-level stringUnit")
        cleaned = SUBSTITUTION_RE.sub("", top_value)
        result.update(placeholder_types(cleaned))

    for name, substitution in (substitutions or {}).items():
        if not isinstance(substitution, dict):
            raise ImportErrorDetail(f"substitution {name!r} must be an object")
        format_specifier = substitution.get("formatSpecifier")
        if not isinstance(format_specifier, str):
            raise ImportErrorDetail(
                f"substitution {name!r} is missing formatSpecifier"
            )
        matches = placeholder_types("%" + format_specifier.lstrip("%"))
        if len(matches) != 1:
            raise ImportErrorDetail(
                f"substitution {name!r} has unsupported formatSpecifier "
                f"{format_specifier!r}"
            )
        expected_leaf_inventory = Counter({matches[0]: 1})
        leaves = string_units(substitution.get("variations", {}))
        if not leaves:
            raise ImportErrorDetail(
                f"substitution {name!r} contains no plural variation stringUnits"
            )
        for leaf_path, unit in leaves:
            value = unit.get("value", "")
            if not isinstance(value, str):
                raise ImportErrorDetail(
                    f"substitution {name!r}{leaf_path} has no text value"
                )
            validate_known_format_syntax(
                value, f"substitution {name!r}{leaf_path}"
            )
            inventory = Counter(placeholder_types(value))
            if inventory != expected_leaf_inventory:
                raise ImportErrorDetail(
                    f"substitution {name!r}{leaf_path} must contain exactly "
                    f"{dict(expected_leaf_inventory)}, got {dict(inventory)}"
                )
        result.update(expected_leaf_inventory)

    referenced_names = set(SUBSTITUTION_RE.findall(top_value or ""))
    if referenced_names != substitution_names:
        raise ImportErrorDetail(
            "top-level substitution references do not match definitions: "
            f"references={sorted(referenced_names)}, "
            f"definitions={sorted(substitution_names)}"
        )

    # No substitutions: a direct unit or each plural leaf contains the complete
    # runtime format. All plural categories must agree on its argument types.
    if not substitutions:
        units = string_units(localization)
        inventories = [
            Counter(placeholder_types(unit.get("value", "")))
            for path, unit in units
            if path != ".stringUnit"
        ]
        for path, unit in units:
            validate_known_format_syntax(
                unit.get("value", ""), f"plural leaf {path}"
            )
        if inventories:
            first = inventories[0]
            if any(inventory != first for inventory in inventories[1:]):
                raise ImportErrorDetail(
                    "plural categories do not preserve the same placeholders"
                )
            return first
    return result


def validate_localization(
    language: str,
    key: str,
    source_entry: dict[str, Any],
    localization: Any,
    allow_translated_state: bool,
    protected_terms: list[str] | None = None,
) -> tuple[int, int]:
    if not isinstance(localization, dict):
        raise ImportErrorDetail(
            f"{language}: {key!r}: localization must be an object"
        )
    units = string_units(localization)
    if not units:
        raise ImportErrorDetail(
            f"{language}: {key!r}: localization contains no stringUnit"
        )

    unchanged = 0
    translated_values: list[str] = []
    for path, unit in units:
        value = unit.get("value")
        state = unit.get("state")
        if not isinstance(value, str) or not value.strip():
            raise ImportErrorDetail(
                f"{language}: {key!r}{path}: value must be nonempty text"
            )
        if state not in ALLOWED_STATES:
            raise ImportErrorDetail(
                f"{language}: {key!r}{path}: unsupported state {state!r}"
            )
        if state == "translated" and not allow_translated_state:
            raise ImportErrorDetail(
                f"{language}: {key!r}{path}: LLM output must use needs_review, "
                "not translated"
            )
        if value == source_text(key, source_entry):
            unchanged += 1
        translated_values.append(value)

    if protected_terms:
        source_values = [
            unit.get("value", "")
            for _, unit in string_units(
                source_entry.get("localizations", {}).get("en", {})
            )
        ]
        source_values.append(source_text(key, source_entry))
        source_blob = "\n".join(source_values)
        translated_blob = "\n".join(translated_values)
        missing_terms = [
            term
            for term in protected_terms
            if term in source_blob and term not in translated_blob
        ]
        if missing_terms:
            raise ImportErrorDetail(
                f"{language}: {key!r}: protected term(s) changed or removed: "
                + ", ".join(missing_terms)
            )

    # Direct strings preserve structural whitespace. Several catalog keys are
    # fragments intentionally carrying a leading/trailing space (`" ahead"`,
    # `" of "`), and multiline alerts rely on their line breaks. Dropping either
    # does not crash and Apple accepts it, but produces glued words or a collapsed
    # paragraph on screen.
    english = source_entry.get("localizations", {}).get("en", {})
    target_unit = localization.get("stringUnit")
    if (
        isinstance(target_unit, dict)
        and not localization.get("variations")
        and not localization.get("substitutions")
        and not english.get("variations")
        and not english.get("substitutions")
    ):
        expected_text = source_text(key, source_entry)
        translated_text = target_unit.get("value", "")
        expected_leading = re.match(r"^[ \t]*", expected_text).group()
        actual_leading = re.match(r"^[ \t]*", translated_text).group()
        expected_trailing = re.search(r"[ \t]*$", expected_text).group()
        actual_trailing = re.search(r"[ \t]*$", translated_text).group()
        if (actual_leading, actual_trailing) != (
            expected_leading,
            expected_trailing,
        ):
            raise ImportErrorDetail(
                f"{language}: {key!r}: boundary whitespace changed: "
                f"expected leading/trailing "
                f"{expected_leading!r}/{expected_trailing!r}, got "
                f"{actual_leading!r}/{actual_trailing!r}"
            )
        if translated_text.count("\n") != expected_text.count("\n"):
            raise ImportErrorDetail(
                f"{language}: {key!r}: newline count changed: expected "
                f"{expected_text.count(chr(10))}, got "
                f"{translated_text.count(chr(10))}"
            )

    expected = expected_placeholder_types(key, source_entry)
    try:
        actual = translated_placeholder_types(localization)
    except ImportErrorDetail as error:
        raise ImportErrorDetail(f"{language}: {key!r}: {error}") from error
    if actual != expected:
        raise ImportErrorDetail(
            f"{language}: {key!r}: placeholder types changed: "
            f"expected {dict(expected)}, got {dict(actual)}"
        )
    return len(units), unchanged


def validate_language(
    path: Path,
    catalog_strings: dict[str, Any],
    allow_translated_state: bool,
    protected_terms: list[str] | None = None,
) -> tuple[str, dict[str, Any], dict[str, int]]:
    document = load_json(path)
    language = document.get("language")
    translations = document.get("translations")
    if not isinstance(language, str) or not language:
        raise ImportErrorDetail(f"{path.name}: missing language tag")
    if not LANGUAGE_TAG_RE.fullmatch(language):
        raise ImportErrorDetail(
            f"{path.name}: {language!r} is not a canonical supported BCP-47 tag "
            "(use hyphens and canonical casing, e.g. pt-BR or zh-Hans)"
        )
    if path.stem != language:
        raise ImportErrorDetail(
            f"{path.name}: filename tag does not match language {language!r}"
        )
    if not isinstance(translations, dict):
        raise ImportErrorDetail(f"{path.name}: translations must be an object")

    expected_keys = set(catalog_strings)
    actual_keys = set(translations)
    missing = expected_keys - actual_keys
    extra = actual_keys - expected_keys
    if missing or extra:
        detail: list[str] = []
        if missing:
            detail.append(
                f"missing {len(missing)} key(s), first: {sorted(missing)[:5]}"
            )
        if extra:
            detail.append(f"extra {len(extra)} key(s), first: {sorted(extra)[:5]}")
        raise ImportErrorDetail(f"{language}: " + "; ".join(detail))

    unit_count = 0
    unchanged = 0
    for key, source_entry in catalog_strings.items():
        units, same = validate_localization(
            language,
            key,
            source_entry,
            translations[key],
            allow_translated_state,
            protected_terms,
        )
        unit_count += units
        unchanged += same
    return language, translations, {
        "keys": len(translations),
        "units": unit_count,
        "unchanged": unchanged,
    }


def validate_info_plist(
    path: Path, document: dict[str, Any], language: str
) -> dict[str, str]:
    values = document.get("infoPlist")
    if not isinstance(values, dict):
        raise ImportErrorDetail(
            f"{path.name}: missing infoPlist object with permission prompts"
        )
    expected = set(INFO_CATALOGS)
    actual = set(values)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ImportErrorDetail(
            f"{language}: infoPlist keys differ; missing={missing}, extra={extra}"
        )
    for key, value in values.items():
        if not isinstance(value, str) or not value.strip():
            raise ImportErrorDetail(
                f"{language}: infoPlist {key!r} must be nonempty text"
            )
        if placeholder_types(value) or SUBSTITUTION_RE.search(value):
            raise ImportErrorDetail(
                f"{language}: infoPlist {key!r} unexpectedly contains a placeholder"
            )
    return values


def dump_catalog(catalog: dict[str, Any]) -> str:
    """Serialize a String Catalog the way Xcode itself writes one.

    Xcode uses `"key" : value` — a space on BOTH sides of the colon — and no
    trailing newline. Python's default `"key": value` is semantically identical
    and utterly unreadable in review: it rewrites every one of the catalog's
    ~255k lines, burying the handful that actually changed. Matching Xcode also
    means a round trip through this tool is a no-op, so opening the catalog in
    Xcode afterwards doesn't churn it straight back.
    """
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))


def compile_catalog(catalog: dict[str, Any]) -> None:
    """Use Apple's compiler as the final authority on String Catalog structure."""

    with tempfile.TemporaryDirectory(prefix="plozz-l10n-import-") as temp:
        temp_path = Path(temp)
        catalog_path = temp_path / "Localizable.xcstrings"
        output_path = temp_path / "compiled"
        catalog_path.write_text(dump_catalog(catalog), encoding="utf-8")
        proc = subprocess.run(
            [
                "xcrun",
                "xcstringstool",
                "compile",
                str(catalog_path),
                "--output-directory",
                str(output_path),
            ],
            text=True,
            capture_output=True,
        )
        if proc.returncode != 0:
            message = (proc.stdout + proc.stderr).strip()
            raise ImportErrorDetail(
                "xcstringstool rejected the merged catalog:\n" + message
            )


def main() -> int:
    args = parse_args()
    catalog_path = args.catalog.resolve()
    catalog = load_json(catalog_path)
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        sys.exit(f"✗ {catalog_path}: missing strings object")

    if args.languages:
        languages = [part.strip() for part in args.languages.split(",") if part.strip()]
        files = [args.input_dir / f"{language}.json" for language in languages]
    else:
        files = sorted(
            path for path in args.input_dir.glob("*.json") if path.name != "source.json"
        )
    if not files:
        sys.exit(f"✗ No language JSON files found in {args.input_dir}")

    merged = copy.deepcopy(catalog)
    merged_info_catalogs = {
        path: load_json(path) for path, _ in set(INFO_CATALOGS.values())
    }
    summaries: dict[str, dict[str, int]] = {}
    try:
        protected_terms = never_translate_terms()
        for path in files:
            document = load_json(path)
            language, translations, summary = validate_language(
                path,
                strings,
                args.allow_translated_state,
                protected_terms,
            )
            for key, localization in translations.items():
                merged["strings"][key].setdefault("localizations", {})[
                    language
                ] = localization
            if args.require_info_plist:
                info_values = validate_info_plist(path, document, language)
                for source_key, value in info_values.items():
                    info_path, catalog_key = INFO_CATALOGS[source_key]
                    entry = merged_info_catalogs[info_path]["strings"][catalog_key]
                    entry.setdefault("localizations", {})[language] = {
                        "stringUnit": {
                            "state": "needs_review",
                            "value": value,
                        }
                    }
            summaries[language] = summary
        compile_catalog(merged)
        for info_catalog in merged_info_catalogs.values():
            compile_catalog(info_catalog)
    except ImportErrorDetail as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1

    for language, summary in sorted(summaries.items()):
        print(
            f"✓ {language:<8} {summary['keys']} keys, {summary['units']} units, "
            f"{summary['unchanged']} unchanged-English unit(s)"
        )
    print("✓ xcstringstool compiled the merged catalog.")
    if args.require_info_plist:
        print("✓ xcstringstool compiled both permission-prompt catalogs.")

    if args.apply:
        catalog_path.write_text(dump_catalog(merged), encoding="utf-8")
        if args.require_info_plist:
            for path, info_catalog in merged_info_catalogs.items():
                path.write_text(dump_catalog(info_catalog), encoding="utf-8")
        print(
            f"✓ Imported {len(summaries)} language(s) into "
            f"{catalog_path.relative_to(REPO)}."
        )
    else:
        print("▸ Dry run only; pass --apply to write the catalog.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
