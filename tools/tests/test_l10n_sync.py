#!/usr/bin/env python3
"""Regression tests for release-language/catalog parity."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "l10n-sync.py"
SPEC = importlib.util.spec_from_file_location("l10n_sync", MODULE_PATH)
assert SPEC and SPEC.loader
l10n_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(l10n_sync)


def entry(*languages: str) -> dict:
    return {
        "localizations": {
            language: {
                "stringUnit": {
                    "state": "needs_review",
                    "value": f"{language} value",
                }
            }
            for language in ("en", *languages)
        }
    }


def info_documents(*languages: str) -> dict[Path, dict]:
    documents: dict[Path, dict] = {}
    for catalog_path, _ in l10n_sync.INFOPLIST_PAIRS:
        keys = (
            ["NSLocalNetworkUsageDescription"]
            if "Resources/InfoPlist" in str(catalog_path)
            else [
                "NSLocalNetworkUsageDescription",
                "NSCameraUsageDescription",
            ]
        )
        documents[catalog_path] = {
            "strings": {key: entry(*languages) for key in keys}
        }
    return documents


class LanguageReleaseParityTests(unittest.TestCase):
    def test_stale_catalog_entries_are_not_active(self) -> None:
        active = entry("nl")
        stale = entry("nl")
        stale["extractionState"] = "stale"

        self.assertEqual(
            l10n_sync.active_catalog_strings(
                {"Active": active, "Removed": stale}
            ),
            {"Active": active},
        )

    def test_exact_release_catalog_permission_parity_passes(self) -> None:
        strings = {"A": entry("nl", "pl"), "B": entry("nl", "pl")}
        self.assertEqual(
            l10n_sync.language_release_problems(
                strings,
                release_ready=["nl", "pl"],
                info_documents=info_documents("nl", "pl"),
            ),
            [],
        )

    def test_catalog_language_hidden_from_picker_fails(self) -> None:
        problems = l10n_sync.language_release_problems(
            {"A": entry("es", "nl")},
            release_ready=["nl"],
            info_documents=info_documents("nl"),
        )
        self.assertTrue(
            any("catalog-only=['es']" in problem for problem in problems),
            problems,
        )

    def test_release_language_missing_app_key_fails(self) -> None:
        problems = l10n_sync.language_release_problems(
            {"A": entry("nl"), "B": entry()},
            release_ready=["nl"],
            info_documents=info_documents("nl"),
        )
        self.assertTrue(
            any("app catalog is missing 1 key" in problem for problem in problems),
            problems,
        )

    def test_permission_catalog_missing_release_language_fails(self) -> None:
        problems = l10n_sync.language_release_problems(
            {"A": entry("nl")},
            release_ready=["nl"],
            info_documents=info_documents(),
        )
        self.assertTrue(
            any(
                "InfoPlist.xcstrings languages must exactly match releaseReady"
                in problem
                for problem in problems
            ),
            problems,
        )

    def test_duplicate_release_tag_fails(self) -> None:
        problems = l10n_sync.language_release_problems(
            {"A": entry("nl")},
            release_ready=["nl", "nl"],
            info_documents=info_documents("nl"),
        )
        self.assertIn(
            "AppLanguage.releaseReady contains duplicate tags",
            problems,
        )


if __name__ == "__main__":
    unittest.main()
