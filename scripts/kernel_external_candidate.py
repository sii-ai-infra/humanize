"""External-evaluator scoring and evidence, independent of built-in geomean policy."""
import hashlib
import math


def handles(report):
    return "external_metric" in report or "external_evidence" in report


def score(report):
    """Accept only complete, correct reports with a declared official metric."""
    validation = report.get("validation", {})
    source = report.get("candidate_identity", {})
    metric = report.get("external_metric")
    rows = report.get("results", [])
    if (report.get("measurement_kind") == "profile" or report.get("kind") != "benchmark"
            or not isinstance(validation, dict) or not isinstance(source, dict)
            or not isinstance(metric, dict) or not isinstance(rows, list)
            or any(not isinstance(row, dict) for row in rows)):
        return None
    required = validation.get("required_cases", [])
    if (not isinstance(required, list) or not required
            or any(not isinstance(name, str) for name in required)
            or len(required) != len(set(required)) or len(rows) != len(required)
            or {row.get("case_name") for row in rows} != set(required)
            or validation.get("cases") != "all" or not validation.get("static_checked")
            or not validation.get("correctness_checked") or not validation.get("device_enabled")
            or not source.get("candidate_committed") or not report.get("source_stable")
            or not isinstance(metric.get("name"), str) or not metric["name"]
            or metric.get("direction") not in ("higher", "lower")
            or type(metric.get("value")) not in (int, float)
            or not math.isfinite(metric["value"]) or not report.get("external_evidence")):
        return None
    try:
        noise = float(report.get("measurement_noise_relative", 0))
        if not math.isfinite(noise) or noise < 0:
            return None
    except (TypeError, ValueError):
        return None
    for row in rows:
        correct = row.get("correctness", {})
        if not isinstance(correct, dict) or correct.get("pass") is not True or correct.get("status") != "pass":
            return None
    return {"metric": metric["name"], "value": metric["value"], "direction": metric["direction"]}


def improves(value, previous, noise):
    """Compare the same named external metric in its declared direction only."""
    if value["metric"] != previous.get("metric") or value["direction"] != previous.get("direction"):
        return False
    gain = value["value"] - previous["value"]
    if value["direction"] == "lower":
        gain = -gain
    return gain > abs(previous["value"]) * noise


def validate_evidence(root, report):
    """Verify raw external evidence and every retained dependency before reuse."""
    evidence = report["external_evidence"]
    raw_path = (root / evidence["path"]).resolve()
    raw_path.relative_to(root / ".humanize")
    if hashlib.sha256(raw_path.read_bytes()).hexdigest() != evidence["sha256"]:
        raise ValueError("External evaluator evidence changed")
    for name, expected in evidence.get("artifacts", {}).items():
        path = (root / name).resolve()
        path.relative_to(root / ".humanize")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"External evaluator artifact changed: {name}")
    for name, expected in evidence.get("inputs", {}).items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
            raise ValueError("Fixed external evaluator input changed")
