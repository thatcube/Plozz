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


def main() -> int:
    args = parse_args()
    try:
        source = load(args.source_delta)
        translated = load(args.translated_delta)
    except ValueError as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1

    source_keys = list(source.get("entries", {}))
    if not source_keys:
        print("✗ Source delta contains no entries.", file=sys.stderr)
        return 1
    if translated.get("sourceCatalogSHA256") != source.get("catalogSHA256"):
        print("✗ Translated delta was produced from another source catalog.", file=sys.stderr)
        return 1
    if translated.get("deltaKeys") != source_keys:
        print("✗ Translated delta key order/set differs from source delta.", file=sys.stderr)
        return 1

    translated_languages = translated.get("languages")
    if not isinstance(translated_languages, dict):
        print("✗ Translated delta is missing its languages object.", file=sys.stderr)
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
        if overlap:
            print(
                f"✗ {language}: full artifact already contains delta keys: "
                f"{sorted(overlap)[:5]}",
                file=sys.stderr,
            )
            return 1
        translations.update(delta)
        pending[artifact_path] = artifact
        print(
            f"✓ {language:<8} {len(translations)} total keys "
            f"(+{len(delta)} delta)"
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
