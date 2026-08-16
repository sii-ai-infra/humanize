#!/usr/bin/env python3
"""Validate one persisted RLCR convergence document without collecting data."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import stat
from pathlib import Path
from typing import Any


SCHEMA_VERSION = "kop-convergence-v1"
STATUSES = {
    "pass",
    "below_target",
    "group_stalled",
    "exhausted",
    "stale",
    "missing",
    "evaluator_error",
}


def _sha256_json(value: Any) -> str:
    payload = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _result(status: str, digest: str, infra: str, reason: str) -> int:
    print(
        json.dumps(
            {"status": status, "digest": digest, "infra": infra, "reason": reason},
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


def validate(path: Path) -> int:
    try:
        file_stat = path.lstat()
    except OSError:
        return _result("missing", "", "ok", "convergence_missing")
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        return _result("stale", "", "ok", "convergence_not_regular_file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return _result("evaluator_error", "", "ok", "convergence_invalid_json")
    if not isinstance(value, dict):
        return _result("evaluator_error", "", "ok", "convergence_not_object")

    recorded_digest = value.get("convergence_digest")
    if not isinstance(recorded_digest, str) or len(recorded_digest) != 64:
        return _result("stale", "", "ok", "convergence_digest_missing")
    unsigned = dict(value)
    unsigned.pop("convergence_digest", None)
    actual_digest = _sha256_json(unsigned)
    if not hmac.compare_digest(recorded_digest, actual_digest):
        return _result("stale", actual_digest, "ok", "convergence_digest_stale")
    if value.get("schema_version") != SCHEMA_VERSION:
        return _result("evaluator_error", recorded_digest, "ok", "convergence_schema_invalid")

    status_value = value.get("status")
    if not isinstance(status_value, str):
        return _result("evaluator_error", recorded_digest, "ok", "convergence_status_missing")
    status = status_value
    infra = "ok"
    reason = "validated"
    eligibility = value.get("eligibility")
    if status == "ineligible":
        if isinstance(eligibility, dict) and eligibility.get("tcb_digests_valid") is False:
            status, infra, reason = "stale", "tcb_tampered", "tcb_digest_invalid"
        elif isinstance(eligibility, dict) and eligibility.get("evidence_freshness_valid") is False:
            status, reason = "stale", "evidence_freshness_invalid"
        else:
            status, reason = "evaluator_error", "promotion_ineligible"
    elif status not in STATUSES:
        status, reason = "evaluator_error", "convergence_status_invalid"

    if status == "pass":
        if value.get("success") is not True or value.get("promotion_evaluated") is not True:
            status, reason = "evaluator_error", "pass_semantics_invalid"
        elif not isinstance(eligibility, dict) or eligibility.get("evidence_freshness_valid") is not True:
            status, reason = "stale", "pass_freshness_unproven"
        elif eligibility.get("tcb_digests_valid") is not True:
            status, infra, reason = "stale", "tcb_tampered", "pass_tcb_unproven"
    elif status in {"below_target", "group_stalled", "exhausted"}:
        if value.get("success") is True:
            status, reason = "evaluator_error", "nonpass_semantics_invalid"

    return _result(status, recorded_digest, infra, reason)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    args = parser.parse_args()
    return validate(Path(args.path))


if __name__ == "__main__":
    raise SystemExit(main())
