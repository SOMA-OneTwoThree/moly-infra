"""Run the candidate's existing read-only report check before any live changes.

Raw child output stays in RAM. Only bounded, typed diagnostic metadata is saved
or printed. The report's SQL/overall budgets and post-deploy gates are unchanged.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

BASE = {
    "daily_report",
    "environment",
    "version",
    "read_only",
    "slack_sent",
    "elapsed_ms",
}
FAILURE = {"phase", "metric", "exception", "sqlstate", "elapsed_ms", "attempt", "retry"}
PHASES = {
    "runtime",
    "engine",
    "rc_snapshot",
    "daily_message",
    "metric",
    "validation",
    "deadline",
    "cleanup",
}
METRICS = {
    "signups",
    "activity",
    "subscriptions",
    "diaries",
    "cost",
    "worker_state",
    "queue_state",
    "subscription_comparison",
    "none",
}
ERRORS = {
    "TimeoutError",
    "ValueError",
    "RuntimeError",
    "ConnectionError",
    "OSError",
    "DBAPIError",
    "ProgrammingError",
    "OperationalError",
    "InterfaceError",
    "InternalError",
    "IntegrityError",
    "DataError",
    "InvalidRequestError",
    "ArgumentError",
    "QueryCanceledError",
    "LockNotAvailableError",
    "UndefinedTableError",
    "UndefinedColumnError",
    "InsufficientPrivilegeError",
    "CannotConnectNowError",
    "ConnectionDoesNotExistError",
    "TooManyConnectionsError",
    "OtherError",
}
MAX_BYTES = 65_536
FORMAT = "daily-report-diagnostics-v1"
WARNING = re.compile(
    r"(?:WARNING:worker\.daily_report:)?report_query metric=(\w+) "
    r"day=\d{4}-\d{2}-\d{2} outcome=failed error=(\w+) sqlstate=(\w+) "
    r"elapsed_ms=(\d+) attempt=(\d+) retry=(True|False)"
)


def integer(value, lower, upper):
    return type(value) is int and lower <= value <= upper


def validate_failure(value):
    return (
        isinstance(value, dict)
        and set(value) == FAILURE
        and isinstance(value["phase"], str)
        and value["phase"] in PHASES
        and isinstance(value["metric"], str)
        and value["metric"] in METRICS
        and isinstance(value["exception"], str)
        and value["exception"] in ERRORS
        and isinstance(value["sqlstate"], str)
        and (
            value["sqlstate"] in {"none", "other"}
            or re.fullmatch(r"[A-Z0-9]{5}", value["sqlstate"]) is not None
        )
        and integer(value["elapsed_ms"], 0, 120_000)
        and integer(value["attempt"], 1, 2)
        and type(value["retry"]) is bool
    )


def validate_report(value, environment, sha):
    if (
        not isinstance(value, dict)
        or value.get("environment") != environment
        or value.get("version") != sha
        or value.get("read_only") is not True
        or value.get("slack_sent") is not False
        or not integer(value.get("elapsed_ms"), 0, 120_000)
    ):
        return False
    if value.get("daily_report") == "ok":
        return set(value) == BASE
    return (
        value.get("daily_report") == "failed"
        and set(value)
        == BASE | {"error", "diagnostic_format", "failures", "diagnostics_truncated"}
        and isinstance(value["error"], str)
        and value["error"] in ERRORS
        and value["diagnostic_format"] == FORMAT
        and isinstance(value["failures"], list)
        and 1 <= len(value["failures"]) <= 16
        and all(validate_failure(record) for record in value["failures"])
        and type(value["diagnostics_truncated"]) is bool
    )


def stderr_records(raw):
    if not isinstance(raw, str):
        return [], False
    records = []
    for line in raw[:MAX_BYTES].splitlines():
        match = WARNING.fullmatch(line)
        if match:
            metric, error, sqlstate, elapsed, attempt, retry = match.groups()
            try:
                elapsed_number, attempt_number = int(elapsed), int(attempt)
            except ValueError:
                continue
            record = {
                "phase": "metric",
                "metric": metric,
                "exception": error,
                "sqlstate": sqlstate,
                "elapsed_ms": elapsed_number,
                "attempt": attempt_number,
                "retry": retry == "True",
            }
            if validate_failure(record):
                records.append(record)
    return records[:16], len(records) > 16 or len(raw.encode("utf-8")) > MAX_BYTES


def failed(
    environment,
    sha,
    elapsed,
    error="OtherError",
    phase="validation",
    records=(),
    truncated=False,
):
    records = list(records) or [
        {
            "phase": phase,
            "metric": "none",
            "exception": error,
            "sqlstate": "none",
            "elapsed_ms": min(120_000, max(0, int(elapsed))),
            "attempt": 1,
            "retry": False,
        }
    ]
    return {
        "daily_report": "failed",
        "environment": environment,
        "version": sha,
        "read_only": True,
        "slack_sent": False,
        "elapsed_ms": min(120_000, max(0, int(elapsed))),
        "error": error,
        "diagnostic_format": FORMAT,
        "failures": records[:16],
        "diagnostics_truncated": truncated,
    }


def parse(raw):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError("duplicate_key")
            value[key] = item
        return value

    def invalid_constant(_value):
        raise ValueError("invalid_number")

    if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_BYTES:
        raise ValueError("output_invalid")
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid_constant)


def write(path, value):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("private_output_invalid")
    descriptor, name = tempfile.mkstemp(prefix=".daily-report-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, sort_keys=True, allow_nan=False)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def run(image, env_file, environment, sha, output):
    expected = (
        "676972757138.dkr.ecr.ap-northeast-2.amazonaws.com/"
        + ("moly-backend-dev:dev-" if environment == "development" else "moly-backend:")
        + sha
    )
    if (
        environment not in {"production", "development"}
        or re.fullmatch(r"[0-9a-f]{40}", sha) is None
        or image != expected
    ):
        raise ValueError("candidate_identity_invalid")
    output = Path(output)
    if output.is_symlink():
        raise ValueError("private_output_invalid")
    output.unlink(missing_ok=True)
    started = time.monotonic()
    records, truncated = [], False
    try:
        probe = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--entrypoint",
                "python",
                image,
                "-c",
                "from pathlib import Path;import sys;sys.exit(0 if Path('/app/scripts/check_daily_report.py').is_file() else 3)",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if probe.returncode:
            report = failed(
                environment,
                sha,
                (time.monotonic() - started) * 1000,
                "RuntimeError",
                "runtime",
            )
        else:
            result = subprocess.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--env-file",
                    str(env_file),
                    "--entrypoint",
                    "python",
                    image,
                    "scripts/check_daily_report.py",
                    "--environment",
                    environment,
                    "--expected-sha",
                    sha,
                ],
                capture_output=True,
                text=True,
                timeout=20,
            )
            elapsed = (time.monotonic() - started) * 1000
            records, truncated = stderr_records(result.stderr)
            try:
                value = parse(result.stdout)
                if validate_report(value, environment, sha):
                    report = value
                    if result.returncode and value["daily_report"] == "ok":
                        report = failed(
                            environment,
                            sha,
                            elapsed,
                            "RuntimeError",
                            "cleanup",
                            records,
                            truncated,
                        )
                elif (
                    isinstance(value, dict)
                    and set(value) == {"daily_report", "error"}
                    and value["daily_report"] == "failed"
                    and isinstance(value["error"], str)
                    and value["error"] in ERRORS
                ):
                    # Rescue 9fa has the original safe two-field failure output.
                    report = failed(
                        environment,
                        sha,
                        elapsed,
                        value["error"],
                        records=records,
                        truncated=truncated,
                    )
                else:
                    report = failed(environment, sha, elapsed)
            except (ValueError, TypeError, UnicodeError):
                report = failed(environment, sha, elapsed)
    except subprocess.TimeoutExpired:
        report = failed(
            environment,
            sha,
            (time.monotonic() - started) * 1000,
            "TimeoutError",
            "deadline",
        )
    except UnicodeError:
        report = failed(environment, sha, (time.monotonic() - started) * 1000)
    except OSError:
        report = failed(
            environment, sha, (time.monotonic() - started) * 1000, "OSError", "runtime"
        )
    write(output, report)
    write(
        output.with_name("daily-report-candidate.stderr.json"),
        {
            "format": "daily-report-stderr-v1",
            "environment": environment,
            "version": sha,
            "records": records,
            "diagnostics_truncated": truncated,
        },
    )
    if report["daily_report"] != "ok":
        for record in report["failures"]:
            print(
                "daily_report_preflight "
                + " ".join(
                    f"{key}={record[key]}"
                    for key in (
                        "phase",
                        "metric",
                        "exception",
                        "sqlstate",
                        "elapsed_ms",
                        "attempt",
                        "retry",
                    )
                )
            )
        return 1
    print("==> candidate readonly daily report preflight OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--env-file", required=True)
    parser.add_argument(
        "--environment", required=True, choices=("production", "development")
    )
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        return run(
            args.image, args.env_file, args.environment, args.expected_sha, args.output
        )
    except Exception:
        print("ERROR: candidate readonly report metadata unavailable")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
