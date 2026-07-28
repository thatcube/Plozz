#!/usr/bin/env python3
"""Export a deterministic, context-rich translation packet from the app catalog."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "App/Resources/Localizable.xcstrings"
DEFAULT_SNAPSHOT = REPO / "tools/l10n-source-snapshot.json"
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output", type=Path, help="JSON packet to write.")
    parser.add_argument(
        "--missing-for",
        metavar="LANGUAGE",
        help="Export keys missing for this language or changed since the snapshot.",
    )
    parser.add_argument(
        "--snapshot",
        type=Path,
        default=DEFAULT_SNAPSHOT,
        help="Committed source fingerprint snapshot.",
    )
    parser.add_argument(
        "--update-snapshot",
        action="store_true",
        help="Write current source fingerprints after exporting.",
    )
    parser.add_argument(
        "--check-snapshot",
        action="store_true",
        help="Fail when missing or source-changed translations are exported.",
    )
    return parser.parse_args()


def source_text(key: str, entry: dict[str, Any]) -> str:
    english = entry.get("localizations", {}).get("en", {})
    direct = english.get("stringUnit", {}).get("value")
    return direct if isinstance(direct, str) else key


def fingerprint(value: Any) -> str:
    canonical = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def app_source_projection(key: str, entry: dict[str, Any]) -> dict[str, Any]:
    return {
        "sourceText": source_text(key, entry),
        "comment": entry.get("comment", ""),
        "englishLocalization": entry.get("localizations", {}).get("en", {}),
    }


def info_source_projection(
    info_catalog: dict[str, Any],
    catalog_key: str,
) -> dict[str, str]:
    entry = info_catalog.get("strings", {}).get(catalog_key, {})
    value = (
        entry.get("localizations", {})
        .get("en", {})
        .get("stringUnit", {})
        .get("value")
    )
    if not isinstance(value, str) or not value:
        raise ValueError(f"missing English permission prompt {catalog_key}")
    return {
        "sourceText": value,
        "comment": entry.get("comment", ""),
    }


def build_snapshot(
    catalog: dict[str, Any],
    info_sources: dict[str, dict[str, str]],
) -> dict[str, Any]:
    app: dict[str, str] = {}
    for key, entry in catalog.get("strings", {}).items():
        if not isinstance(entry, dict) or entry.get("shouldTranslate") is False:
            continue
        app[key] = fingerprint(app_source_projection(key, entry))
    return {
        "version": 1,
        "app": app,
        "infoPlist": {
            key: fingerprint(value) for key, value in info_sources.items()
        },
    }


def export_packet(
    catalog: dict[str, Any],
    missing_for: str | None = None,
    snapshot: dict[str, Any] | None = None,
    info_sources: dict[str, dict[str, str]] | None = None,
    info_localizations: dict[str, dict[str, str]] | None = None,
) -> dict[str, Any]:
    snapshot = snapshot or {"app": {}, "infoPlist": {}}
    entries: dict[str, Any] = {}
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue
        projection = app_source_projection(key, entry)
        requires_refresh = (
            snapshot.get("app", {}).get(key) != fingerprint(projection)
        )
        if (
            missing_for is not None
            and missing_for in entry.get("localizations", {})
            and not requires_refresh
        ):
            continue
        entries[key] = projection | {"requiresRefresh": requires_refresh}

    info_entries: dict[str, Any] = {}
    for key, projection in (info_sources or {}).items():
        requires_refresh = (
            snapshot.get("infoPlist", {}).get(key) != fingerprint(projection)
        )
        has_translation = (
            missing_for is not None
            and isinstance(info_localizations, dict)
            and isinstance(info_localizations.get(key), dict)
            and missing_for in info_localizations[key]
        )
        if missing_for is not None and has_translation and not requires_refresh:
            continue
        info_entries[key] = projection | {"requiresRefresh": requires_refresh}
    canonical = json.dumps(
        catalog,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "sourceLanguage": catalog.get("sourceLanguage", "en"),
        "catalogSHA256": hashlib.sha256(canonical).hexdigest(),
        "missingFor": missing_for,
        "entries": entries,
        "infoPlistEntries": info_entries,
    }


def main() -> int:
    args = parse_args()
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"✗ Could not read {CATALOG.relative_to(REPO)}: {error}", file=sys.stderr)
        return 1

    try:
        snapshot = (
            json.loads(args.snapshot.read_text(encoding="utf-8"))
            if args.snapshot.exists()
            else {"app": {}, "infoPlist": {}}
        )
        loaded_info_catalogs: dict[Path, dict[str, Any]] = {}
        info_sources: dict[str, dict[str, str]] = {}
        info_localizations: dict[str, dict[str, str]] = {}
        for artifact_key, (path, catalog_key) in INFO_CATALOGS.items():
            if path not in loaded_info_catalogs:
                loaded_info_catalogs[path] = json.loads(
                    path.read_text(encoding="utf-8")
                )
            info_catalog = loaded_info_catalogs[path]
            info_sources[artifact_key] = info_source_projection(
                info_catalog,
                catalog_key,
            )
            info_localizations[artifact_key] = (
                info_catalog.get("strings", {})
                .get(catalog_key, {})
                .get("localizations", {})
            )
        packet = export_packet(
            catalog,
            args.missing_for,
            snapshot=snapshot,
            info_sources=info_sources,
            info_localizations=info_localizations,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"✗ Could not build source packet: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(packet, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    qualifier = (
        f" missing for {args.missing_for}" if args.missing_for else ""
    )
    print(
        f"✓ Exported {len(packet['entries'])} app key(s) and "
        f"{len(packet['infoPlistEntries'])} permission prompt(s){qualifier} "
        f"to {args.output}."
    )
    if args.check_snapshot and (
        packet["entries"] or packet["infoPlistEntries"]
    ):
        print(
            "✗ Localization source snapshot is not current.",
            file=sys.stderr,
        )
        return 1
    if args.update_snapshot:
        current_snapshot = build_snapshot(catalog, info_sources)
        args.snapshot.write_text(
            json.dumps(current_snapshot, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(f"✓ Updated source snapshot {args.snapshot.relative_to(REPO)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
