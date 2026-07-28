#!/usr/bin/env python3
"""Tests for deterministic full/delta translation packets."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "l10n-export-source.py"
SPEC = importlib.util.spec_from_file_location("l10n_export_source", MODULE_PATH)
assert SPEC and SPEC.loader
l10n_export = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(l10n_export)


def localization(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


class TranslationSourceExportTests(unittest.TestCase):
    def catalog(self) -> dict:
        return {
            "sourceLanguage": "en",
            "strings": {
                "Natural text": {
                    "comment": "Context.",
                    "localizations": {"nl": localization("Nederlandse tekst")},
                },
                "semantic.key": {
                    "comment": "Semantic context.",
                    "localizations": {"en": localization("Default English")},
                },
                "not translated": {
                    "shouldTranslate": False,
                    "localizations": {},
                },
            },
        }

    def test_full_packet_uses_semantic_default_and_omits_opt_out(self) -> None:
        packet = l10n_export.export_packet(self.catalog())
        self.assertEqual(
            set(packet["entries"]),
            {"Natural text", "semantic.key"},
        )
        self.assertEqual(
            packet["entries"]["semantic.key"]["sourceText"],
            "Default English",
        )
        self.assertEqual(
            packet["entries"]["Natural text"]["sourceText"],
            "Natural text",
        )

    def test_delta_packet_contains_only_keys_missing_language(self) -> None:
        packet = l10n_export.export_packet(self.catalog(), missing_for="nl")
        self.assertEqual(set(packet["entries"]), {"semantic.key"})
        self.assertEqual(packet["missingFor"], "nl")

    def test_packet_hash_is_deterministic_across_dictionary_order(self) -> None:
        first = self.catalog()
        second = {
            "strings": dict(reversed(list(first["strings"].items()))),
            "sourceLanguage": "en",
        }
        self.assertEqual(
            l10n_export.export_packet(first)["catalogSHA256"],
            l10n_export.export_packet(second)["catalogSHA256"],
        )


if __name__ == "__main__":
    unittest.main()
