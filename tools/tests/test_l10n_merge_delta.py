#!/usr/bin/env python3
"""CLI-level regression tests for multilingual delta merging."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / "l10n-merge-delta.py"


def write(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False),
        encoding="utf-8",
    )


class TranslationDeltaMergeTests(unittest.TestCase):
    def fixture(
        self,
        root: Path,
        *,
        overlap: bool = False,
        refresh_overlap: bool = False,
        permission_prompt: bool = False,
        permission_refresh: bool = True,
    ) -> tuple[Path, Path, Path]:
        source = root / "source.json"
        translated = root / "translated.json"
        artifacts = root / "artifacts"
        artifacts.mkdir()
        write(
            source,
            {
                "catalogSHA256": "abc",
                "entries": {
                    "New copy": {"requiresRefresh": refresh_overlap},
                    "Count %@": {},
                },
                "infoPlistEntries": (
                    {"iOS.Prompt": {"requiresRefresh": permission_refresh}}
                    if permission_prompt
                    else {}
                ),
            },
        )
        write(
            translated,
            {
                "sourceCatalogSHA256": "abc",
                "deltaKeys": ["New copy", "Count %@"],
                "infoPlistKeys": ["iOS.Prompt"] if permission_prompt else [],
                "languages": {
                    "de": {
                        "New copy": {
                            "stringUnit": {
                                "state": "needs_review",
                                "value": "Neuer Text",
                            }
                        },
                        "Count %@": {
                            "stringUnit": {
                                "state": "needs_review",
                                "value": "Anzahl %@",
                            }
                        },
                    }
                },
                "infoPlistLanguages": (
                    {"de": {"iOS.Prompt": "Neue Berechtigung"}}
                    if permission_prompt
                    else {}
                ),
            },
        )
        translations = {
            "Existing": {
                "stringUnit": {
                    "state": "needs_review",
                    "value": "Vorhanden",
                }
            }
        }
        if overlap:
            translations["New copy"] = {
                "stringUnit": {
                    "state": "needs_review",
                    "value": "Schon vorhanden",
                }
            }
        write(
            artifacts / "de.json",
            {
                "language": "de",
                "languageName": "Deutsch",
                "translations": translations,
                "infoPlist": {"iOS.Prompt": "Alte Berechtigung"},
            },
        )
        return source, translated, artifacts

    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(TOOL), *arguments],
            text=True,
            capture_output=True,
        )

    def test_apply_adds_delta_without_touching_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(Path(temp))
            result = self.run_tool(
                str(source),
                str(translated),
                str(artifacts),
                "--apply",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = json.loads((artifacts / "de.json").read_text())
            self.assertEqual(artifact["languageName"], "Deutsch")
            self.assertEqual(len(artifact["translations"]), 3)
            self.assertEqual(
                artifact["translations"]["New copy"]["stringUnit"]["value"],
                "Neuer Text",
            )

    def test_source_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(Path(temp))
            value = json.loads(translated.read_text())
            value["sourceCatalogSHA256"] = "wrong"
            write(translated, value)
            result = self.run_tool(str(source), str(translated), str(artifacts))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("another source catalog", result.stderr)

    def test_existing_delta_key_fails_instead_of_overwriting(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(
                Path(temp), overlap=True
            )
            result = self.run_tool(str(source), str(translated), str(artifacts))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("already contains delta keys", result.stderr)

    def test_source_changed_delta_key_is_refreshed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(
                Path(temp),
                overlap=True,
                refresh_overlap=True,
            )
            result = self.run_tool(
                str(source),
                str(translated),
                str(artifacts),
                "--apply",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = json.loads((artifacts / "de.json").read_text())
            self.assertEqual(
                artifact["translations"]["New copy"]["stringUnit"]["value"],
                "Neuer Text",
            )

    def test_generated_translated_state_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(Path(temp))
            value = json.loads(translated.read_text())
            value["languages"]["de"]["New copy"]["stringUnit"]["state"] = "translated"
            write(translated, value)
            result = self.run_tool(str(source), str(translated), str(artifacts))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must all remain needs_review", result.stderr)

    def test_changed_permission_prompt_is_refreshed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(
                Path(temp),
                permission_prompt=True,
            )
            result = self.run_tool(
                str(source),
                str(translated),
                str(artifacts),
                "--apply",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            artifact = json.loads((artifacts / "de.json").read_text())
            self.assertEqual(
                artifact["infoPlist"]["iOS.Prompt"],
                "Neue Berechtigung",
            )

    def test_permission_prompt_overlap_requires_refresh_authorization(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source, translated, artifacts = self.fixture(
                Path(temp),
                permission_prompt=True,
                permission_refresh=False,
            )
            result = self.run_tool(str(source), str(translated), str(artifacts))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("without refresh authorization", result.stderr)


if __name__ == "__main__":
    unittest.main()
