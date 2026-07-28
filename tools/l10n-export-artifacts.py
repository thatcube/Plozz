#!/usr/bin/env python3
"""Rebuild isolated full-language artifacts from the committed catalogs."""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "App/Resources/Localizable.xcstrings"
INFO_CATALOG_PATHS = {
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output_dir", type=Path)
    parser.add_argument(
        "--languages",
        help="Comma-separated tags. Defaults to every non-source catalog language.",
    )
    return parser.parse_args()


def load(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path}: root must be an object")
    return value


def catalog_languages(catalog: dict[str, Any]) -> list[str]:
    source_language = catalog.get("sourceLanguage", "en")
    languages: set[str] = set()
    for entry in catalog.get("strings", {}).values():
        if not isinstance(entry, dict) or entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        if isinstance(localizations, dict):
            languages.update(localizations)
    languages.discard(source_language)
    return sorted(languages)


def build_artifact(
    catalog: dict[str, Any],
    permission_catalogs: dict[str, tuple[dict[str, Any], str]],
    language: str,
) -> dict[str, Any]:
    translations: dict[str, Any] = {}
    for key, entry in catalog.get("strings", {}).items():
        if not isinstance(entry, dict) or entry.get("shouldTranslate") is False:
            continue
        localization = entry.get("localizations", {}).get(language)
        if isinstance(localization, dict):
            translations[key] = copy.deepcopy(localization)

    info_plist: dict[str, str] = {}
    for artifact_key, (info_catalog, catalog_key) in permission_catalogs.items():
        value = (
            info_catalog.get("strings", {})
            .get(catalog_key, {})
            .get("localizations", {})
            .get(language, {})
            .get("stringUnit", {})
            .get("value")
        )
        if not isinstance(value, str) or not value:
            raise ValueError(
                f"{language}: missing permission translation {artifact_key}"
            )
        info_plist[artifact_key] = value

    return {
        "language": language,
        "languageName": language,
        "translations": translations,
        "infoPlist": info_plist,
    }


def main() -> int:
    args = parse_args()
    try:
        catalog = load(CATALOG)
        loaded_info_catalogs: dict[Path, dict[str, Any]] = {}
        permission_catalogs: dict[str, tuple[dict[str, Any], str]] = {}
        for artifact_key, (path, catalog_key) in INFO_CATALOG_PATHS.items():
            loaded_info_catalogs.setdefault(path, load(path))
            permission_catalogs[artifact_key] = (
                loaded_info_catalogs[path],
                catalog_key,
            )
        languages = (
            [part.strip() for part in args.languages.split(",") if part.strip()]
            if args.languages
            else catalog_languages(catalog)
        )
        if not languages:
            raise ValueError("catalog contains no non-source languages")

        args.output_dir.mkdir(parents=True, exist_ok=True)
        for language in languages:
            artifact = build_artifact(catalog, permission_catalogs, language)
            output = args.output_dir / f"{language}.json"
            output.write_text(
                json.dumps(artifact, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            print(
                f"✓ {language:<8} "
                f"{len(artifact['translations'])} existing translation(s)"
            )
    except ValueError as error:
        print(f"✗ {error}", file=sys.stderr)
        return 1

    print(f"✓ Exported {len(languages)} language artifact(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
