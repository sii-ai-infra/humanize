"""Bind existing evaluation reports to Git; keep best/final in pipeline state.

Copied into generated bench directories. No candidate snapshots or extra ledger.
"""

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import uuid


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def read_json(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError(f"Expected an object: {path}")
    return value


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        try:
            json.dump(value, file, indent=2, sort_keys=True, allow_nan=False)
            file.write("\n")
            file.close()
            os.replace(file.name, path)
        finally:
            if os.path.exists(file.name):
                os.unlink(file.name)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def scopes(root):
    state = root / ".pipeline/state.json"
    paths = read_json(state).get("candidate_paths", ["solution"]) if state.exists() else ["solution"]
    if not isinstance(paths, list) or not paths or "solution" not in paths:
        raise ValueError("candidate_paths must include solution")
    for name in paths:
        if not isinstance(name, str) or not name or Path(name).is_absolute() or any(c in name for c in ":*?["):
            raise ValueError("Candidate paths must be task-relative")
        if any(part in ("..", ".git", ".humanize", ".pipeline", "baseline", "bench", "docs") for part in Path(name).parts):
            raise ValueError(f"Invalid candidate path: {name}")
        if name in (".", "contract.md", "prompt.md", "AGENTS.md", "docs"):
            raise ValueError(f"Invalid candidate path: {name}")
        (root / name).resolve().relative_to(root)
    return sorted(set(paths))


def files(root, paths):
    result = {}
    for name in paths:
        item = root / name
        candidates = sorted(item.rglob("*")) if item.is_dir() else [item]
        for path in candidates:
            if "__pycache__" in path.parts or path.suffix == ".pyc" or not path.exists():
                continue
            if path.is_symlink():
                raise ValueError(f"Symlink cannot certify candidate/config: {path}")
            if path.is_file():
                relative = path.relative_to(root).as_posix()
                result[relative] = [hashlib.sha256(path.read_bytes()).hexdigest(), bool(path.stat().st_mode & 0o111)]
    return result


def commit_files(root, commit, paths):
    result = {}
    for item in git(root, "ls-tree", "-rz", commit, "--", *paths).split(b"\0"):
        if not item:
            continue
        info, name = item.split(b"\t", 1)
        mode, kind, object_id = info.split()
        if kind != b"blob" or mode not in (b"100644", b"100755"):
            raise ValueError("Only regular Git files are supported for candidate recovery")
        result[name.decode()] = [hashlib.sha256(git(root, "cat-file", "blob", object_id.decode())).hexdigest(), mode == b"100755"]
    return result


def identity(root):
    root = root.resolve()
    paths = scopes(root)
    candidate = files(root, paths)
    if not candidate:
        raise ValueError("No candidate source files")
    config_paths = ["baseline", "bench", "contract.md", "prompt.md", "shapes.yaml", "docs/optimization-objective.md"]
    loops = sorted((root / ".humanize/rlcr").glob("*/benchmark-command.sh"))
    if loops:
        config_paths.extend([loops[-1].relative_to(root).as_posix(), loops[-1].with_name("benchmark-timeout").relative_to(root).as_posix()])
    config = files(root, config_paths)
    environment = {key: os.environ.get(key) for key in (
        "ASCEND_RT_VISIBLE_DEVICES", "ASCEND_VISIBLE_DEVICES", "ASCEND_DEVICE_ID", "CUDA_VISIBLE_DEVICES",
        "PYTHONPATH", "LD_LIBRARY_PATH", "ASCEND_HOME_PATH", "ASCEND_OPP_PATH",
    )}
    for package in ("torch", "torch-npu", "triton"):
        try:
            environment[package] = importlib.metadata.version(package)
        except importlib.metadata.PackageNotFoundError:
            environment[package] = None
    environment["host"] = platform.node()
    environment["python"] = platform.python_version()
    for variable in ("ASCEND_HOME_PATH", "ASCEND_OPP_PATH"):
        if environment.get(variable):
            for name in ("version.cfg", "version.info"):
                path = Path(environment[variable]) / name
                if path.is_file():
                    environment[f"{variable}/{name}"] = hashlib.sha256(path.read_bytes()).hexdigest()
    commit, committed = None, False
    try:
        if Path(git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
            raise ValueError("Task must own its Git repository")
        commit = git(root, "rev-parse", "HEAD").decode().strip()
        committed = candidate == commit_files(root, commit, paths)
    except subprocess.CalledProcessError:
        pass
    return {"measured_commit": commit, "candidate_paths": paths, "candidate_files": candidate,
            "candidate_sha256": digest(candidate), "candidate_committed": committed,
            "configuration_sha256": digest({"files": config, "environment": environment})}


def equivalent(left, right):
    return all(left.get(key) == right.get(key) for key in (
        "candidate_paths", "candidate_sha256", "configuration_sha256",
    ))


def state_update(root, key, value):
    path = root / ".pipeline/state.json"
    if path.exists():
        state = read_json(path)
        state[key] = value
        write_json(path, state)


def score(report):
    """Use evaluator-produced full-case correctness/static/device evidence."""
    validation = report.get("validation", {})
    source = report.get("candidate_identity", {})
    if not isinstance(validation, dict) or not isinstance(source, dict):
        return None
    required = validation.get("required_cases", [])
    rows = report.get("results", [])
    if (not isinstance(required, list) or any(not isinstance(name, str) for name in required)
            or not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows)):
        return None
    try:
        noise = float(report.get("measurement_noise_relative", 0))
        if not math.isfinite(noise) or noise < 0:
            return None
    except (TypeError, ValueError):
        return None
    if (report.get("kind") != "benchmark" or not required or len(required) != len(set(required))
            or validation.get("cases") != "all" or not validation.get("static_checked")
            or not validation.get("correctness_checked") or not validation.get("device_enabled")
            or not source.get("candidate_committed") or not report.get("source_stable")
            or len(rows) != len(required) or {row.get("case_name") for row in rows} != set(required)):
        return None
    ratios = []
    for row in rows:
        correct = row.get("correctness", {})
        profiler = row.get("profiler", {})
        if not isinstance(correct, dict) or not isinstance(profiler, dict):
            return None
        if correct.get("status") != "pass" or correct.get("pass") is not True:
            return None
        try:
            base, cand = float(profiler["baseline_us"]), float(profiler["candidate_us"])
            if not all(math.isfinite(v) and v > 0 for v in (base, cand)):
                return None
            for side, total in (("baseline", base), ("candidate", cand)):
                kernels = profiler[f"{side}_kernels"]
                durations = [float(kernel["total_us"]) for kernel in kernels]
                if not durations or not all(math.isfinite(v) and v > 0 for v in durations):
                    return None
                if not math.isclose(sum(durations), total, rel_tol=1e-6, abs_tol=1e-6):
                    return None
            ratio = base / cand
            if not math.isfinite(ratio) or ratio <= 0:
                return None
            ratios.append(ratio)
        except (KeyError, TypeError, ValueError):
            return None
    return {"geomean": math.exp(sum(math.log(v) for v in ratios) / len(ratios)), "min_case": min(ratios)}


def load_candidate(root, ref):
    path = (root / ref["report"]).resolve()
    path.relative_to(root / ".humanize")
    if hashlib.sha256(path.read_bytes()).hexdigest() != ref["report_sha256"]:
        raise ValueError("Best report changed")
    report = read_json(path)
    value = score(report)
    if value is None or value != ref["score"] or report["candidate_identity"] != ref["identity"]:
        raise ValueError("Best reference does not match full evidence")
    old = report["candidate_identity"]
    if commit_files(root, old["measured_commit"], old["candidate_paths"]) != old["candidate_files"]:
        raise ValueError("Measured Git version does not match report")
    return report


def save_report(root, before, report):
    after = identity(root)
    report.update(candidate_identity=before, source_stable=equivalent(before, after))
    path = root / ".humanize/bench" / (uuid.uuid4().hex + ".json")
    report["report_path"] = path.relative_to(root).as_posix()
    write_json(path, report)
    value = score(report)
    state_path = root / ".pipeline/state.json"
    if value is not None and state_path.exists():
        state = read_json(state_path)
        old = state.get("best_candidate")
        use_new = True
        if old and old.get("identity", {}).get("configuration_sha256") == before["configuration_sha256"]:
            try:
                old_report = load_candidate(root, old)
                # Honor noise only if the evaluator provided it; invent no threshold.
                noise = max(float(report.get("measurement_noise_relative", 0)),
                            float(old_report.get("measurement_noise_relative", 0)))
                use_new = (old.get("protocol_sha256") == digest(report.get("settings", {}))
                           and value["geomean"] > old["score"]["geomean"] * (1 + noise))
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
                use_new = True
        if use_new:
            state_update(root, "best_candidate", {
                "identity": before, "report": path.relative_to(root).as_posix(),
                "report_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "score": value, "protocol_sha256": digest(report.get("settings", {})),
            })
    return path


def finish(root, reason):
    """At normal completion/budget, restore only a proven candidate scope."""
    state_path = root / ".pipeline/state.json"
    state = read_json(state_path) if state_path.exists() else {}
    best = state.get("best_candidate")
    result = {"status": "unconfirmed", "reason": reason, "best_report": best.get("report") if best else None}
    if reason == "stop":
        result["detail"] = "STOP preserves state; no restoration or validation started"
        state_update(root, "final_delivery", result)
        return result
    try:
        if not best:
            result.update(validation_required=True, detail="No full valid candidate recorded")
            state_update(root, "final_delivery", result)
            return result
        best_report = load_candidate(root, best)
        target = best["identity"]
        current = identity(root)
        configuration_changed = target["configuration_sha256"] != current["configuration_sha256"]
        if target["candidate_paths"] != current["candidate_paths"]:
            raise ValueError("Candidate scope differs from best")
        restoring = state.get("final_delivery", {})
        if target["candidate_sha256"] != current["candidate_sha256"] or not current["candidate_committed"]:
            recovering = ((restoring.get("status") == "restoring" or restoring.get("restoration_pending"))
                          and restoring.get("head_before_restore") == current["measured_commit"]
                          and restoring.get("best_report") == best["report"])
            if not current["candidate_committed"] and not recovering:
                raise ValueError("Commit current candidate before restoring best")
            # Prevent overwriting untracked/ignored candidate files even during recovery.
            tracked = set(commit_files(root, current["measured_commit"], current["candidate_paths"])) | set(target["candidate_files"])
            if set(current["candidate_files"]) - tracked:
                raise ValueError("Untracked candidate files require inspection")
            result.update(status="restoring", restoration_pending=True, head_before_restore=current["measured_commit"])
            state_update(root, "final_delivery", result)
            git(root, "restore", f"--source={target['measured_commit']}", "--staged", "--worktree", "--", *target["candidate_paths"])
            restored = identity(root)
            if (target["candidate_sha256"] != restored["candidate_sha256"]
                    or current["configuration_sha256"] != restored["configuration_sha256"]):
                raise ValueError("Restored candidate does not match full report")
            git(root, "commit", "-m", "Restore best validated candidate", "--", *target["candidate_paths"])
        final = identity(root)
        if not final["candidate_committed"] or target["candidate_sha256"] != final["candidate_sha256"]:
            raise ValueError("Final Git candidate does not match report")
        if configuration_changed:
            result.update(status="unconfirmed", restoration_pending=False, validation_required=True,
                          final_commit=final["measured_commit"], detail="Configuration changed; full validation required")
            state_update(root, "final_delivery", result)
            return result
        result.update(status="valid", restoration_pending=False, measured_commit=target["measured_commit"], final_commit=final["measured_commit"],
                      candidate_sha256=final["candidate_sha256"], score=best["score"], validation_reused=True)
        gates = best_report.get("gates", {})
        result["performance_target_met"] = None
        if isinstance(gates, dict) and gates.get("checks_active", True) and isinstance(gates.get("success"), bool):
            result["performance_target_met"] = gates["success"]
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        result.update(status="unconfirmed", detail=str(error))
    state_update(root, "final_delivery", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("identity", "finish"))
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--reason", choices=("complete", "maxiter", "stop"), default="complete")
    args = parser.parse_args()
    root = args.project_root.resolve()
    value = identity(root) if args.action == "identity" else finish(root, args.reason)
    print(json.dumps(value, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Candidate evidence unavailable: {error}", file=sys.stderr)
        raise SystemExit(1)
