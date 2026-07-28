#!/usr/bin/env python3
"""Merge one reviewed multilingual delta into isolated full-language artifacts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source_delta", type=Path)
    parser.add_argument("translated_delta", type=Path)
    parser.add_argument("artifact_dir", type=Path)
    parser.add_argument(
        "--languages",
        help="Comma-separated tags. Defaults to every language in the delta.",
    )
    parser.add_argument("--apply", action="store_true")
    return parser.parse_args()


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path}: root must be an object")
    return value


def generated_units_are_review_pending(value: Any) -> bool:
    found = False

    def visit(child: Any) -> bool:
        nonlocal found
        if isinstance(child, dict):
            unit = child.get("stringUnit")
            if isinstance(unit, dict):
                found = True
                if unit.get("state") != "needs_review":
                    return False
            return all(visit(value) for value in child.values())
        if isinstance(child, list):
            return all(visit(value) for value in child)
        return True

    return visit(value) and found


def main() -> int:
    args = parse_args()
    try:
        source = load(args.source_delta)
        translated = load(args.translated_delta)
    except ValueError as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1

    source_keys = list(source.get("entries", {}))
    source_info_keys = list(source.get("infoPlistEntries", {}))
    if not source_keys and not source_info_keys:
        print("✗ Source delta contains no entries or permission prompts.", file=sys.stderr)
        return 1
    if translated.get("sourceCatalogSHA256") != source.get("catalogSHA256"):
        print("✗ Translated delta was produced from another source catalog.", file=sys.stderr)
        return 1
    if translated.get("deltaKeys") != source_keys:
        print("✗ Translated delta key order/set differs from source delta.", file=sys.stderr)
        return 1
    if translated.get("infoPlistKeys", []) != source_info_keys:
        print(
            "✗ Translated permission-prompt order/set differs from source delta.",
            file=sys.stderr,
        )
        return 1

    translated_languages = translated.get("languages")
    if not isinstance(translated_languages, dict):
        print("✗ Translated delta is missing its languages object.", file=sys.stderr)
        return 1
    translated_info_languages = translated.get("infoPlistLanguages", {})
    if not isinstance(translated_info_languages, dict):
        print("✗ Translated delta has an invalid infoPlistLanguages object.", file=sys.stderr)
        return 1
    languages = (
        [part.strip() for part in args.languages.split(",") if part.strip()]
        if args.languages
        else sorted(translated_languages)
    )

    pending: dict[Path, dict[str, Any]] = {}
    for language in languages:
        delta = translated_languages.get(language)
        if not isinstance(delta, dict) or set(delta) != set(source_keys):
            print(
                f"✗ {language}: delta must contain exactly {len(source_keys)} keys.",
                file=sys.stderr,
            )
            return 1
        invalid_states = [
            key
            for key, value in delta.items()
            if not generated_units_are_review_pending(value)
        ]
        if invalid_states:
            print(
                f"✗ {language}: generated units must all remain needs_review: "
                f"{invalid_states[:5]}",
                file=sys.stderr,
            )
            return 1
        info_delta = translated_info_languages.get(language, {})
        if not isinstance(info_delta, dict) or set(info_delta) != set(source_info_keys):
            print(
                f"✗ {language}: permission delta must contain exactly "
                f"{len(source_info_keys)} keys.",
                file=sys.stderr,
            )
            return 1
        invalid_prompts = [
            key
            for key, value in info_delta.items()
            if not isinstance(value, str) or not value
        ]
        if invalid_prompts:
            print(
                f"✗ {language}: permission translations must be nonempty text: "
                f"{invalid_prompts[:5]}",
                file=sys.stderr,
            )
            return 1
        artifact_path = args.artifact_dir / f"{language}.json"
        try:
            artifact = load(artifact_path)
        except ValueError as error:
            print(f"✗ {error}", file=sys.stderr)
            return 1
        if artifact.get("language") != language:
            print(
                f"✗ {artifact_path.name}: language tag does not match {language}.",
                file=sys.stderr,
            )
            return 1
        translations = artifact.get("translations")
        if not isinstance(translations, dict):
            print(f"✗ {artifact_path.name}: missing translations object.", file=sys.stderr)
            return 1
        overlap = set(source_keys) & set(translations)
        refreshable = {
            key
            for key, entry in source.get("entries", {}).items()
            if isinstance(entry, dict) and entry.get("requiresRefresh") is True
        }
        unsafe_overlap = overlap - refreshable
        if unsafe_overlap:
            print(
                f"✗ {language}: full artifact already contains delta keys: "
                f"{sorted(unsafe_overlap)[:5]}",
                file=sys.stderr,
            )
            return 1
        translations.update(delta)
        info_plist = artifact.get("infoPlist")
        if not isinstance(info_plist, dict):
            print(f"✗ {artifact_path.name}: missing infoPlist object.", file=sys.stderr)
            return 1
        refreshable_prompts = {
            key
            for key, entry in source.get("infoPlistEntries", {}).items()
            if isinstance(entry, dict) and entry.get("requiresRefresh") is True
        }
        unsafe_prompt_overlap = (
            set(info_delta) & set(info_plist)
        ) - refreshable_prompts
        if unsafe_prompt_overlap:
            print(
                f"✗ {language}: artifact already contains permission prompts "
                f"without refresh authorization: {sorted(unsafe_prompt_overlap)[:5]}",
                file=sys.stderr,
            )
            return 1
        info_plist.update(info_delta)
        pending[artifact_path] = artifact
        print(
            f"✓ {language:<8} {len(translations)} total keys "
            f"(+{len(delta) - len(overlap)} new, {len(overlap)} refreshed, "
            f"{len(info_delta)} permission prompt(s))"
        )

    if args.apply:
        for path, artifact in pending.items():
            path.write_text(
                json.dumps(artifact, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
        print(f"✓ Updated {len(pending)} language artifact(s).")
    else:
        print("▸ Dry run only; pass --apply to write artifacts.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
