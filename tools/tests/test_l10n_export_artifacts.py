#!/usr/bin/env python3
"""Regression tests for rebuilding isolated translation artifacts."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "l10n-export-artifacts.py"
SPEC = importlib.util.spec_from_file_location("l10n_export_artifacts", MODULE_PATH)
assert SPEC and SPEC.loader
l10n_export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(l10n_export)


def localization(value: str) -> dict:
    return {"stringUnit": {"state": "needs_review", "value": value}}


class TranslationArtifactExportTests(unittest.TestCase):
    def catalog(self) -> dict:
        return {
            "sourceLanguage": "en",
            "strings": {
                "Existing": {
                    "localizations": {
                        "de": localization("Vorhanden"),
                        "en": localization("Existing"),
                    }
                },
                "Missing": {"localizations": {}},
                "Brand": {
                    "shouldTranslate": False,
                    "localizations": {},
                },
            },
        }

    def permissions(self) -> dict:
        catalog = {
            "strings": {
                "Prompt": {
                    "localizations": {
                        "de": localization("Berechtigung"),
                    }
                }
            }
        }
        return {
            "tvOS.Prompt": (catalog, "Prompt"),
            "iOS.Prompt": (catalog, "Prompt"),
        }

    def test_discovers_non_source_languages(self) -> None:
        self.assertEqual(l10n_export.catalog_languages(self.catalog()), ["de"])

    def test_builds_partial_artifact_ready_for_delta_merge(self) -> None:
        artifact = l10n_export.build_artifact(
            self.catalog(),
            self.permissions(),
            "de",
        )
        self.assertEqual(artifact["language"], "de")
        self.assertEqual(set(artifact["translations"]), {"Existing"})
        self.assertNotIn("Missing", artifact["translations"])
        self.assertNotIn("Brand", artifact["translations"])
        self.assertEqual(
            artifact["infoPlist"],
            {
                "tvOS.Prompt": "Berechtigung",
                "iOS.Prompt": "Berechtigung",
            },
        )

    def test_missing_permission_translation_fails(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing permission translation"):
            l10n_export.build_artifact(
                self.catalog(),
                self.permissions(),
                "fr",
            )


if __name__ == "__main__":
    unittest.main()
