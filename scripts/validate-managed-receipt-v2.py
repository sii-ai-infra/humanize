#!/usr/bin/env python3
"""Decode the fixed Node broker's v2 receipt; never grant user authority.

This pure protocol boundary does not evaluate metrics, inspect task files,
write lifecycle state, advance rounds, invoke models, or retry benchmarks.
The Node broker must independently prove an owner_requested_repair delivery.
Legacy v1 scripts and receipts do not use this decoder.
"""
import argparse
import json
import re
import sys

LIMIT = 64 * 1024
FIELDS = {"schema", "outcome", "decision", "reason_code", "reason", "evidence_sha256"}
PAUSES = {
    ("invalid_spec", "pause", "invalid_spec"),
    ("unmeasurable", "pause", "measurement_missing"),
    ("unmeasurable", "pause", "raw_limit"),
    ("unmeasurable", "pause", "report_limit"),
    ("unmeasurable", "pause", "output_limit"),
    ("platform_blocked", "pause", "platform_blocked"),
    ("reference_blocked", "pause", "reference_blocked"),
}
NEGATIVES = {
    ("target_not_met", "target_not_met"),
    ("correctness_failed", "correctness_failed"),
    ("correctness_failed", "candidate_error"),
    ("invalid_result", "invalid_result"),
    ("invalid_result", "candidate_unchanged"),
}
OWNER_REPAIR = ("unmeasurable", "repair", "owner_requested_repair")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate receipt field")
        result[key] = value
    return result


def decode(raw: bytes, phase: str) -> dict:
    if phase not in {"round", "completion"} or len(raw) > LIMIT:
        raise ValueError("invalid receipt phase or size")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, RecursionError) as error:
        raise ValueError("invalid receipt encoding or nesting") from error
    if not isinstance(value, dict) or set(value) != FIELDS:
        raise ValueError("receipt fields differ")
    if any(not isinstance(item, str) for item in value.values()):
        raise ValueError("receipt fields must be strings")
    expected_schema = "managed-round-status-v2" if phase == "round" else "managed-completion-v2"
    if value["schema"] != expected_schema:
        raise ValueError("receipt schema differs")
    if not re.fullmatch(r"[a-f0-9]{64}", value["evidence_sha256"]):
        raise ValueError("receipt evidence hash differs")
    reason = value["reason"]
    if (not reason.strip() or any(ord(c) < 32 and c not in "\n\t" for c in reason)
            or any(0xD800 <= ord(c) <= 0xDFFF for c in reason)
            or len(reason.encode("utf-8")) > 8192):
        raise ValueError("receipt reason is empty or exceeds its bound")
    combination = (value["outcome"], value["decision"], value["reason_code"])
    if combination not in allowed_combinations(phase):
        raise ValueError("receipt outcome/decision/reason combination differs")
    return value


def allowed_combinations(phase):
    if phase not in {"round", "completion"}:
        raise ValueError("invalid phase")
    allowed = set(PAUSES)
    allowed.add(OWNER_REPAIR)
    if phase == "round":
        allowed.add(("passed", "continue", "passed"))
        allowed.update((outcome, "continue", code) for outcome, code in NEGATIVES)
    else:
        allowed.add(("passed", "pass", "passed"))
        allowed.add(("acceptance_not_met", "repair", "acceptance_not_met"))
        allowed.update((outcome, "repair", code) for outcome, code in NEGATIVES)
    return allowed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=["round", "completion"], required=True)
    args = parser.parse_args()
    try:
        value = decode(sys.stdin.buffer.read(LIMIT + 1), args.phase)
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        return 0
    except (ValueError, UnicodeError, RecursionError):
        print("Invalid managed v2 receipt; preserve lifecycle and reconcile the original operation.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
