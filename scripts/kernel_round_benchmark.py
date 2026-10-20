"""Existing Stop benchmark entrypoint with version-aware receipts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid

from kernel_candidate import equivalent, identity, read_json


def receipt(path, round_number, command, value):
    text = f"""# Round {round_number} Full Benchmark

- Command: `{command}`
- Git HEAD: `{value['identity'].get('measured_commit') or 'unknown'}`
- Status: **{value['status']}**
- Exit code: **{value.get('exit_code', 'pending')}**
- Full log: `{value['log']}`
- Full report: `{value.get('report') or 'unknown'}`
- Full evaluation completed: **{value.get('full_completed', False)}**

## Program record
```json
{json.dumps(value, sort_keys=True)}
```
"""
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(text)
    temporary.replace(path)


def run(args):
    root, loop = args.project_root.resolve(), args.loop_dir.resolve()
    prefix = "final" if args.final else f"round-{args.round}"
    result = loop / f"{prefix}-benchmark.md"
    log = loop / f"{prefix}-benchmark.log"
    command = args.command_file.read_text()
    before = identity(root)
    command_sha = hashlib.sha256(command.encode()).hexdigest()
    if result.exists():
        try:
            old = json.loads(result.read_text().split("```json\n", 1)[1].split("\n```", 1)[0])
            if old.get("status") in ("starting", "running"):
                # Only our synchronous process can be retried here. An uncertain
                # job must be inspected by its owner, never duplicated by Stop.
                try:
                    check = os.killpg if old["status"] == "running" else os.kill
                    check(old["pid"], 0)
                except ProcessLookupError:
                    if not args.retry:
                        return
                else:
                    raise RuntimeError("Original benchmark is still running; inspect it before retry")
            if (not args.retry and equivalent(old["identity"], before)
                    and old["identity"].get("candidate_committed") == before["candidate_committed"]
                    and old["command_sha256"] == command_sha and old["timeout_seconds"] == args.timeout
                    and (loop / old["log"]).is_file()):
                # Failed/partial attempts remain failure evidence for review.
                # Only a completed structured report is a full cache hit.
                if old.get("report"):
                    report = (root / old["report"]).resolve()
                    report.relative_to(root / ".humanize")
                    if hashlib.sha256(report.read_bytes()).hexdigest() != old.get("report_sha256"):
                        raise ValueError("Old full report changed")
                return
        except (ValueError, KeyError, OSError, IndexError):
            pass
        attempt = uuid.uuid4().hex
        archived_log = f"{prefix}-benchmark-{attempt}.log"
        if log.exists():
            log.rename(loop / archived_log)
        text = result.read_text().replace(f"`{log.name}`", f"`{archived_log}`")
        # Keep the original body and adjust only the old receipt's log link.
        if '"log":' in text:
            text = text.replace(f'"log": "{log.name}"', f'"log": "{archived_log}"')
        (loop / f"{prefix}-benchmark-{attempt}.md").write_text(text)
    value = {"identity": before, "command_sha256": command_sha, "timeout_seconds": args.timeout,
             "status": "starting", "pid": os.getpid(), "log": log.name, "started_at": time.time()}
    receipt(result, args.round, command, value)
    with log.open("w") as output:
        process = subprocess.Popen(["bash", "-lc", command], cwd=root, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        value["pid"] = process.pid
        value["status"] = "running"
        receipt(result, args.round, command, value)
        try:
            code = process.wait(timeout=args.timeout)
            value["status"] = "passed" if code == 0 else "failed"
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            code, value["status"] = 124, "timeout"
    value.update(exit_code=code, finished_at=time.time(), source_stable=equivalent(before, identity(root)))
    matches = re.findall(r"^Full evaluation report: (.+)$", log.read_text(errors="replace"), re.M)
    for name in reversed(matches):
        try:
            path = (root / name).resolve()
            path.relative_to(root / ".humanize")
            report = read_json(path)
            required = report.get("validation", {}).get("required_cases", [])
            if report.get("kind") != "benchmark" or not equivalent(before, report["candidate_identity"]):
                continue
            value.update(report=name, report_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                         full_completed=bool(required and report["validation"].get("cases") == "all"
                                             and len(report["results"]) == len(required)
                                             and {row.get("case_name") for row in report["results"]} == set(required)
                                             and before["candidate_committed"]
                                             and value["source_stable"] and report.get("source_stable")))
            break
        except (ValueError, KeyError, OSError):
            continue
    receipt(result, args.round, command, value)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--loop-dir", type=Path, required=True)
    parser.add_argument("--round", type=int, required=True)
    parser.add_argument("--command-file", type=Path, required=True)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--retry", action="store_true")
    parser.add_argument("--final", action="store_true")
    run(parser.parse_args())
