"""Candidate report receipt safety: fake child processes only, no DB/AWS/Docker."""

from contextlib import redirect_stdout
from copy import deepcopy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
from unittest import mock
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "report_preflight", ROOT / "scripts/verify_daily_report_preflight.py"
)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)
SHA = "a" * 40
IMAGE = "676972757138.dkr.ecr.ap-northeast-2.amazonaws.com/moly-backend:" + SHA


def success():
    return {
        "daily_report": "ok",
        "environment": "production",
        "version": SHA,
        "read_only": True,
        "slack_sent": False,
        "elapsed_ms": 120,
    }


def failure():
    return report.failed(
        "production",
        SHA,
        2501,
        "ValueError",
        records=[
            {
                "phase": "metric",
                "metric": "diaries",
                "exception": "DBAPIError",
                "sqlstate": "57014",
                "elapsed_ms": 2501,
                "attempt": 1,
                "retry": False,
            }
        ],
    )


class ReportPreflightTests(unittest.TestCase):
    def execute(self, stdout, *, stderr="", rc=0, probe=0, exception=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            env = path / "backend.env.next"
            env.write_text("OPENAI_API_KEY=secret-config-canary\n")
            target = path / "daily-report-candidate.json"
            target.write_text('{"stale":true}')
            responses = [
                SimpleNamespace(
                    returncode=probe, stdout="", stderr="probe-secret-canary"
                )
            ]
            responses.append(
                exception
                or SimpleNamespace(returncode=rc, stdout=stdout, stderr=stderr)
            )
            output = io.StringIO()
            with (
                mock.patch.object(
                    report.subprocess, "run", side_effect=responses
                ) as child,
                redirect_stdout(output),
            ):
                result = report.run(IMAGE, env, "production", SHA, target)
            stored = json.loads(target.read_text())
            diagnostics = json.loads(
                (path / "daily-report-candidate.stderr.json").read_text()
            )
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                (path / "daily-report-candidate.stderr.json").stat().st_mode & 0o777,
                0o600,
            )
            calls = child.call_args_list
            if len(calls) == 2:
                command = calls[1].args[0]
                self.assertIn(str(env), command)
                self.assertEqual(command[-1], SHA)
                self.assertNotIn("--show", command)
                self.assertEqual(calls[1].kwargs["timeout"], 20)
            safe = output.getvalue() + json.dumps(stored) + json.dumps(diagnostics)
            self.assertNotIn("canary", safe)
            return result, stored, diagnostics, output.getvalue(), len(calls)

    def test_legacy_success_six_fields_are_preserved_for_compatible_rescue(self):
        result, stored, _, output, _ = self.execute(json.dumps(success()))
        self.assertEqual(result, 0)
        self.assertEqual(stored, success())
        self.assertIn("preflight OK", output)

    def test_structured_failure_retains_only_typed_metadata_and_fails(self):
        value = failure()
        result, stored, _, output, _ = self.execute(json.dumps(value), rc=1)
        self.assertEqual(result, 1)
        self.assertEqual(stored, value)
        self.assertIn("metric=diaries", output)
        self.assertIn("sqlstate=57014", output)

    def test_legacy_failure_uses_only_matching_safe_stderr_warning(self):
        stderr = (
            "unrelated secret-stderr-canary SQL text\n"
            "report_query metric=diaries day=2026-11-05 outcome=failed error=DBAPIError "
            "sqlstate=57014 elapsed_ms=2501 attempt=1 retry=False\n"
        )
        result, stored, diagnostics, _, _ = self.execute(
            json.dumps({"daily_report": "failed", "error": "ValueError"}),
            stderr=stderr,
            rc=1,
        )
        self.assertEqual(result, 1)
        self.assertEqual(stored["failures"][0]["metric"], "diaries")
        self.assertNotIn("day", diagnostics["records"][0])
        self.assertEqual(diagnostics["records"], stored["failures"])

    def test_missing_checker_never_attempts_report_or_uses_previous_receipt(self):
        result, stored, _, _, calls = self.execute("", probe=3)
        self.assertEqual(result, 1)
        self.assertEqual(calls, 1)
        self.assertEqual(stored["failures"][0]["phase"], "runtime")

    def test_cold_connection_timeout_is_failed_without_sensitive_exception_text(self):
        error = subprocess.TimeoutExpired(
            ["secret-command-canary"], 20, output="secret-body-canary"
        )
        result, stored, _, _, _ = self.execute("", exception=error)
        self.assertEqual(result, 1)
        self.assertEqual(stored["error"], "TimeoutError")
        self.assertEqual(stored["failures"][0]["phase"], "deadline")

    def test_success_body_with_nonzero_exit_still_fails(self):
        result, stored, _, _, _ = self.execute(json.dumps(success()), rc=1)
        self.assertEqual(result, 1)
        self.assertEqual(stored["failures"][0]["phase"], "cleanup")

    def test_invalid_duplicate_or_private_output_never_crosses_metadata_boundary(self):
        for raw in (
            "secret-output-canary",
            '{"secret":"secret-body-canary"}',
            '{"daily_report":"failed","daily_report":"ok"}',
            '{"elapsed_ms":NaN}',
        ):
            with self.subTest(raw_length=len(raw)):
                result, stored, _, _, _ = self.execute(
                    raw, stderr="secret-stderr-canary", rc=1
                )
                self.assertEqual(result, 1)
                self.assertEqual(stored["daily_report"], "failed")
                self.assertTrue(report.validate_report(stored, "production", SHA))

    def test_failure_fields_are_bounded_and_allowlisted(self):
        mutations = [
            ("phase", "secret-phase-canary"),
            ("metric", "private_metric"),
            ("exception", "secret-error-canary"),
            ("sqlstate", "private-query-canary"),
            ("elapsed_ms", True),
            ("elapsed_ms", 120001),
            ("attempt", 0),
            ("attempt", 3),
            ("retry", 1),
            ("phase", []),
        ]
        for key, value in mutations:
            invalid = deepcopy(failure())
            invalid["failures"][0][key] = value
            with self.subTest(key=key):
                self.assertFalse(report.validate_report(invalid, "production", SHA))
        invalid = failure()
        invalid["failures"] *= 17
        self.assertFalse(report.validate_report(invalid, "production", SHA))
        invalid["failures"] = []
        self.assertFalse(report.validate_report(invalid, "production", SHA))

    def test_unknown_stderr_or_oversized_counts_are_discarded_not_logged(self):
        records, _ = report.stderr_records(
            "report_query metric=diaries day=2026-11-05 outcome=failed "
            "error=DBAPIError sqlstate=57014 elapsed_ms="
            + "9" * 5000
            + " attempt=1 retry=False"
        )
        self.assertEqual(records, [])
