from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "release-notes.py"


class ReleaseNotesToolTests(unittest.TestCase):
    def fixture(self, root: Path, items: list[object]) -> Path:
        path = root / "ReleaseNotes.json"
        path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "releases": [
                        {
                            "id": "release/001",
                            "version": "2026.8.1",
                            "build": 1,
                            "releasedAt": "2026-08-01",
                            "sections": [
                                {
                                    "category": "New",
                                    "items": items,
                                }
                            ],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return path

    def run_tool(
        self, catalog: Path, *arguments: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(TOOL),
                "--catalog",
                str(catalog),
                *arguments,
            ],
            text=True,
            capture_output=True,
        )

    def test_render_filters_platform_items_and_keeps_shared_strings(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            catalog = self.fixture(
                Path(temp),
                [
                    "Shared",
                    {"text": "TV only", "platforms": ["tvOS"]},
                    {"text": "Phone only", "platforms": ["iOS"]},
                ],
            )

            tv = self.run_tool(
                catalog,
                "render",
                "--release-id",
                "release/001",
                "--platform",
                "tvOS",
            )
            ios = self.run_tool(
                catalog,
                "render",
                "--release-id",
                "release/001",
                "--platform",
                "iOS",
            )

            self.assertEqual(tv.returncode, 0, tv.stderr)
            self.assertEqual(tv.stdout.strip(), "New\n• Shared\n• TV only")
            self.assertEqual(ios.returncode, 0, ios.stderr)
            self.assertEqual(ios.stdout.strip(), "New\n• Shared\n• Phone only")

    def test_validate_rejects_empty_platforms(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            catalog = self.fixture(
                Path(temp),
                [{"text": "Invalid", "platforms": []}],
            )

            result = self.run_tool(catalog, "validate")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no platforms", result.stderr)

    def test_validate_rejects_unknown_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            catalog = self.fixture(
                Path(temp),
                [{"text": "Invalid", "platforms": ["visionOS"]}],
            )

            result = self.run_tool(catalog, "validate")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unknown platform", result.stderr)

    def test_render_warns_when_platform_has_no_notes(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            catalog = self.fixture(
                Path(temp),
                [{"text": "TV only", "platforms": ["tvOS"]}],
            )

            result = self.run_tool(
                catalog,
                "render",
                "--release-id",
                "release/001",
                "--platform",
                "iOS",
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "\n")
            self.assertIn("has no iOS notes", result.stderr)


if __name__ == "__main__":
    unittest.main()
