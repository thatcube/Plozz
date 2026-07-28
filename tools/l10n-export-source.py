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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output", type=Path, help="JSON packet to write.")
    parser.add_argument(
        "--missing-for",
        metavar="LANGUAGE",
        help="Export only keys with no localization for this language.",
    )
    return parser.parse_args()


def source_text(key: str, entry: dict[str, Any]) -> str:
    english = entry.get("localizations", {}).get("en", {})
    direct = english.get("stringUnit", {}).get("value")
    return direct if isinstance(direct, str) else key


def export_packet(
    catalog: dict[str, Any],
    missing_for: str | None = None,
) -> dict[str, Any]:
    entries: dict[str, Any] = {}
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue
        if (
            missing_for is not None
            and missing_for in entry.get("localizations", {})
        ):
            continue
        entries[key] = {
            "sourceText": source_text(key, entry),
            "comment": entry.get("comment", ""),
            "englishLocalization": entry.get("localizations", {}).get("en", {}),
        }
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
    }


def main() -> int:
    args = parse_args()
    try:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"✗ Could not read {CATALOG.relative_to(REPO)}: {error}", file=sys.stderr)
        return 1

    packet = export_packet(catalog, args.missing_for)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(packet, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    qualifier = (
        f" missing for {args.missing_for}" if args.missing_for else ""
    )
    print(
        f"✓ Exported {len(packet['entries'])} translation key(s){qualifier} "
        f"to {args.output}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
