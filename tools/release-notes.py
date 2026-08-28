#!/usr/bin/env python3
"""Validate and render Plozz's committed release-notes catalog."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = ROOT / "App" / "Resources" / "ReleaseNotes.json"
CATEGORIES = ("New", "Updated", "Fixed")


def fail(message: str) -> None:
    raise ValueError(message)


def load_catalog(path: Path) -> dict[str, Any]:
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"release-notes catalog not found: {path}")
    except json.JSONDecodeError as error:
        fail(f"invalid JSON in {path}: {error}")

    if catalog.get("schemaVersion") != 1:
        fail("schemaVersion must be 1")
    releases = catalog.get("releases")
    if not isinstance(releases, list):
        fail("releases must be an array")

    ids: set[str] = set()
    builds: set[int] = set()
    previous_build: int | None = None
    previous_version: tuple[int, int, int] | None = None
    for release in releases:
        if not isinstance(release, dict):
            fail("every release must be an object")
        release_id = release.get("id")
        build = release.get("build")
        version = release.get("version")
        released_at = release.get("releasedAt")
        sections = release.get("sections")

        if not isinstance(build, int) or build <= 0:
            fail(f"{release_id or 'release'} has an invalid build")
        if release_id != f"release/{build:03d}":
            fail(f"{release_id} does not match build {build}")
        if release_id in ids:
            fail(f"duplicate release id: {release_id}")
        if build in builds:
            fail(f"duplicate release build: {build}")
        if previous_build is not None and build >= previous_build:
            fail("releases must be sorted by descending build")
        if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
            fail(f"{release_id} has an invalid version")
        version_tuple = tuple(int(part) for part in version.split("."))
        if previous_version is not None and version_tuple > previous_version:
            fail("release versions must be sorted newest first")
        if not isinstance(released_at, str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}", released_at
        ):
            fail(f"{release_id} has an invalid releasedAt date")
        if not isinstance(sections, list) or not sections:
            fail(f"{release_id} must have release-note sections")

        section_names = [section.get("category") for section in sections]
        expected = [category for category in CATEGORIES if category in section_names]
        if section_names != expected:
            fail(f"{release_id} sections must follow New, Updated, Fixed order")
        for section in sections:
            items = section.get("items")
            if not isinstance(items, list) or not items:
                fail(f"{release_id} {section.get('category')} section is empty")
            if any(not isinstance(item, str) or not item.strip() for item in items):
                fail(f"{release_id} contains an empty release-note item")
            if len(set(items)) != len(items):
                fail(f"{release_id} repeats a release-note item")

        ids.add(release_id)
        builds.add(build)
        previous_build = build
        previous_version = version_tuple

    return catalog


def selected_release(
    catalog: dict[str, Any],
    release_id: str,
    version: str | None,
    build: int | None,
) -> dict[str, Any]:
    release = next(
        (entry for entry in catalog["releases"] if entry["id"] == release_id),
        None,
    )
    if release is None:
        fail(f"release id {release_id} is not in the catalog")
    if version is not None and release["version"] != version:
        fail(
            f"{release_id} is version {release['version']}, "
            f"but the build is version {version}"
        )
    if build is not None and release["build"] != build:
        fail(
            f"{release_id} is build {release['build']}, "
            f"but App Store Connect assigned build {build}"
        )
    return release


def render(release: dict[str, Any]) -> str:
    blocks = []
    for section in release["sections"]:
        items = "\n".join(f"• {item}" for item in section["items"])
        blocks.append(f"{section['category']}\n{items}")
    return "\n\n".join(blocks)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    subparsers = result.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--release-id")
    validate.add_argument("--version")
    validate.add_argument("--build", type=int)

    render_command = subparsers.add_parser("render")
    render_command.add_argument("--release-id", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        catalog = load_catalog(args.catalog)
        if args.command == "validate":
            if args.release_id:
                release = selected_release(
                    catalog,
                    args.release_id,
                    args.version,
                    args.build,
                )
                print(
                    f"Validated {release['id']} "
                    f"(version {release['version']}, build {release['build']})"
                )
            else:
                print(f"Validated {len(catalog['releases'])} releases")
        else:
            release = selected_release(catalog, args.release_id, None, None)
            print(render(release))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
