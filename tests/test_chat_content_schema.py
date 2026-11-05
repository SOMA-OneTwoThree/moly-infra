"""Trusted known-delta augmentation, synthetic catalog only; no database/client."""

from copy import deepcopy
import importlib.util
from pathlib import Path
from unittest import mock
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "trusted_schema", ROOT / "scripts/verify_chat_content_schema.py"
)
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)


class SchemaCompatibilityTests(unittest.TestCase):
    def test_frozen_delta_is_only_four_columns_two_nullability_three_checks_and_paired_deletion(
        self,
    ):
        delta = schema.REVIEWED_DELTA
        self.assertEqual(set(delta), {"columns", "constraints", "functions"})
        self.assertEqual(
            set(delta["columns"]),
            {
                "public.messages.content",
                "public.greetings.content",
                "public.messages.content_ciphertext",
                "public.messages.content_chars",
                "public.greetings.content_ciphertext",
                "public.idempotency_keys.response_ciphertext",
            },
        )
        self.assertEqual(len(delta["constraints"]), 3)
        for name, value in delta["constraints"].items():
            self.assertFalse(value["validated"])
            self.assertIn("NOT VALID", value["definition"])
        self.assertEqual(
            set(delta["functions"]), {"public.begin_subject_deletion(uuid,uuid)"}
        )
        self.assertIn(
            "response_ciphertext = NULL",
            next(iter(delta["functions"].values()))["definition"],
        )
        self.assertEqual(
            schema.BASELINE_DIGEST,
            "5843b2aefad6de4729dbb3982931e5ad04a80a9081891f1c315d066a35b4e5ae",
        )

    def test_unknown_legacy_catalog_is_never_normalized(self):
        with self.assertRaisesRegex(ValueError, "unsupported_legacy_catalog"):
            schema.reviewed_upgrade({"columns": {}})

    def test_upgrade_preserves_every_unrelated_baseline_entry_and_detects_delta_tamper(
        self,
    ):
        baseline = {
            "columns": {"unrelated": {"not_null": True}},
            "constraints": {"unrelated": "original"},
            "functions": {"unrelated": "original"},
            "relation_grants": {"unrelated": "preserved"},
        }
        expected = deepcopy(baseline)
        for section, entries in schema.REVIEWED_DELTA.items():
            expected[section].update(entries)
        with (
            mock.patch.object(
                schema, "BASELINE_DIGEST", schema.catalog_digest(baseline)
            ),
            mock.patch.object(
                schema, "EXPANDED_DIGEST", schema.catalog_digest(expected)
            ),
        ):
            self.assertEqual(schema.reviewed_upgrade(baseline), expected)
            self.assertNotIn("public.messages.content_chars", baseline["columns"])
            with mock.patch.dict(
                schema.REVIEWED_DELTA["columns"], {"unexpected": "bad"}
            ):
                with self.assertRaisesRegex(ValueError, "invalid_reviewed_delta"):
                    schema.reviewed_upgrade(baseline)
