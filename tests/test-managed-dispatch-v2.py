"""Actual main-hook dispatch tests; no model, device, or business execution."""
import io
import json
import os
from pathlib import Path
import shutil
import stat
import hashlib
import time
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = "d920d5df4ec214b207eefa2151b92087eaeb4fb3"


class DispatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="managed-dispatch-")
        cls.plugin = Path(cls.tmp.name) / "plugin"
        cls.plugin.mkdir()
        data = subprocess.check_output(["git", "archive", BASE], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(cls.plugin, filter="data")
        cls.hook = cls.plugin / "hooks/loop-codex-stop-hook.sh"
        cls.old = cls.hook.read_bytes()
        cls.new = (ROOT / "hooks/loop-codex-stop-hook.sh").read_bytes()
        cls.head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        assert cls.new == subprocess.check_output(["git", "show", cls.head + ":hooks/loop-codex-stop-hook.sh"], cwd=ROOT)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.install_product(BASE)
        tmp = tempfile.TemporaryDirectory(prefix="dispatch-task-")
        self.addCleanup(tmp.cleanup)
        self.task = Path(tmp.name)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(("HUMANIZE_", "CODEX_", "CLAUDE_", "GIT_", "XDG_CONFIG_HOME"))}
        (self.task / "fixture-home").mkdir()
        (self.task / "no-external-cli").mkdir()
        guard = self.task / "no-external-cli/codex"
        guard.write_text("#!/bin/sh\necho 'Unexpected real-model route in fixture' >&2\nexit 97\n")
        guard.chmod(0o755)
        self.env.update(CLAUDE_PROJECT_DIR=str(self.task), XDG_CACHE_HOME=str(self.task / "cache"),
                        HOME=str(self.task / "fixture-home"),
                        PATH=str(guard.parent) + os.pathsep + self.env["PATH"], GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_NOSYSTEM="1")
        self.env.pop("HUMANIZE_MANAGED_PIPELINE", None)
        self.env.pop("HUMANIZE_MANAGED_RELIABILITY_V1", None)
        subprocess.run(["git", "init", "-q", "--initial-branch=main", str(self.task)], check=True, env=self.env)
        for key, value in [("user.email", "fixture@example.invalid"), ("user.name", "Fixture")]:
            subprocess.run(["git", "-C", str(self.task), "config", key, value], check=True, env=self.env)
        (self.task / ".gitignore").write_text(".humanize/\ncache/\nfixture-home/\nno-external-cli/\nfixture-bin/\n")
        (self.task / "plan.md").write_text("# Plan\n\nPreserve the original native loop.\n")
        subprocess.run(["git", "-C", str(self.task), "add", "plan.md", ".gitignore"], check=True, env=self.env)
        subprocess.run(["git", "-C", str(self.task), "commit", "-qm", "fixture"], check=True, env=self.env)
        self.loop = self.task / ".humanize/rlcr/2026-11-08_00-00-00"
        self.loop.mkdir(parents=True)
        shutil.copyfile(self.task / "plan.md", self.loop / "plan.md")
        self.state = ("---\ncurrent_round: 0\nmax_iterations: 5\ncodex_model: gpt-5.5\n"
                      "codex_effort: high\ncodex_timeout: 60\npush_every_round: false\n"
                      "full_review_round: 5\nplan_file: plan.md\nplan_tracked: false\n"
                      "start_branch: main\nbase_branch: main\nbase_commit: deadbeef\n"
                      "review_started: false\nask_codex_question: false\nagent_teams: false\n"
                      "session_id: session\n---\n").encode()
        (self.loop / "state.md").write_bytes(self.state)
        for path in [self.plugin / "hooks/lib/managed-completion-v2.sh", self.plugin / "scripts/run-round-benchmark-v2.sh"]:
            path.unlink(missing_ok=True)

    def native_files(self):
        return {str(p.relative_to(self.loop)): p.read_bytes() for p in self.loop.rglob("*") if p.is_file()}

    def run_hook(self, body, additions=None):
        self.hook.write_bytes(body)
        self.hook.chmod(0o755)
        return subprocess.run([str(self.hook)], input=b'{"session_id":"session"}', capture_output=True,
                              cwd=self.task, env=dict(self.env, **(additions or {})), timeout=15)

    def test_legacy_managed_and_unmanaged_outputs_and_state_are_byte_identical(self):
        for managed in [False, True]:
            with self.subTest(managed=managed):
                additions = {"HUMANIZE_MANAGED_RELIABILITY_V1": "1"} if managed else {}
                before = self.native_files()
                old = self.run_hook(self.old, additions)
                old_files = self.native_files()
                self.assertEqual(old.returncode, 0, old.stderr)
                self.assertEqual(json.loads(old.stdout)["decision"], "block")
                self.assertTrue(json.loads(old.stdout)["reason"])
                # Same plugin pathname and same task pathname. Nothing in the
                # raw output is normalized to make the comparison pass.
                self.assertEqual(old_files, before)
                new = self.run_hook(self.new, additions)
                self.assertEqual((new.returncode, new.stdout, new.stderr), (old.returncode, old.stdout, old.stderr))
                self.assertEqual(self.native_files(), old_files)

    def test_unknown_empty_and_conflicting_modes_block_before_any_transition(self):
        for additions in [
            {"HUMANIZE_MANAGED_PIPELINE": ""},
            {"HUMANIZE_MANAGED_PIPELINE": "v3"},
            *[{"HUMANIZE_MANAGED_PIPELINE": "v2", "HUMANIZE_MANAGED_RELIABILITY_V1": value} for value in ["1", "0", ""]],
        ]:
            with self.subTest(additions=additions):
                before = self.native_files()
                result = self.run_hook(self.new, additions)
                self.assertEqual(result.returncode, 0, result.stderr)
                value = json.loads(result.stdout)
                self.assertEqual(value["decision"], "block")
                self.assertEqual(value["managed_v2_error"], "unsupported_mode")
                self.assertEqual(self.native_files(), before)

    def tree_snapshot(self):
        result = {".":("dir", stat.S_IMODE(self.task.stat().st_mode), None)}
        for path in sorted(self.task.rglob("*")):
            meta = path.lstat()
            mode = stat.S_IMODE(meta.st_mode)
            key = str(path.relative_to(self.task))
            if stat.S_ISLNK(meta.st_mode):
                result[key] = ("link", mode, os.readlink(path))
            elif stat.S_ISDIR(meta.st_mode):
                result[key] = ("dir", mode, None)
            elif stat.S_ISREG(meta.st_mode):
                result[key] = ("file", mode, path.read_bytes())
            else:
                self.fail("unexpected fixture filesystem object: " + key)
        return result

    def restore_tree(self, snapshot):
        shutil.rmtree(self.task)
        self.task.mkdir()
        for key, (kind, mode, body) in snapshot.items():
            path = self.task / key
            path.parent.mkdir(parents=True, exist_ok=True)
            if kind == "dir":
                path.mkdir(exist_ok=True)
            elif kind == "link":
                path.symlink_to(body)
                continue
            else:
                path.write_bytes(body)
            path.chmod(mode)

    def install_product(self, revision):
        shutil.rmtree(self.plugin)
        self.plugin.mkdir()
        data = subprocess.check_output(["git", "archive", revision], cwd=ROOT)
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(self.plugin, filter="data")
        if revision == "HEAD":
            for name in ["hooks/lib/managed-completion-v2.sh", "scripts/validate-managed-receipt-v2.py",
                         "scripts/prepare-managed-repair-v2.sh", "scripts/apply-managed-repair-v2.py",
                         "scripts/run-round-benchmark-v2.sh", "scripts/run-round-benchmark-v2.py"]:
                self.assertTrue((self.plugin / name).is_file(), name)

    def prepare_v2_completion(self, decision="pass", privacy=True):
        self.install_product("HEAD")
        actual_base = subprocess.check_output(["git", "-C", str(self.task), "rev-parse", "HEAD"]).strip()
        state = self.state.replace(b"deadbeef", actual_base).replace(
            b"agent_teams: false\n", b"agent_teams: false\nprivacy_mode: " + (b"true" if privacy else b"false") + b"\n")
        (self.loop / "state.md").unlink()
        (self.loop / "finalize-state.md").write_bytes(state)
        (self.loop / "finalize-summary.md").write_text("# Original final summary\n")
        (self.loop / "benchmark-command.sh").write_text("original protected benchmark command\n")
        return self.stage_v2_completion(decision)

    def stage_v2_completion(self, decision="pass", operation_id="01ARZ3NDEKTSV4RRFFQ69G5FAV"):
        # Each new Stop gate needs a new operation, even when its native round
        # is unchanged. A previous phase's staged completion is not its answer.
        command = self.loop / "benchmark-command.sh"
        temporary = tempfile.TemporaryDirectory(prefix="dispatch-completion-operation-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        brokers = root / "brokers"
        brokers.mkdir()
        trace = root / "trace"
        answer = root / "answer.json"
        fixture = '''#!/usr/bin/python3.12 -I
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["COMPLETION_FIXTURE_TRACE"], "a") as stream:
    stream.write(name + "\\n")
if name != "completion" or sys.stdin.buffer.read():
    raise SystemExit(97)
sys.stdout.buffer.write(pathlib.Path(os.environ["COMPLETION_FIXTURE_ANSWER"]).read_bytes())
'''
        for name in ["completion", "benchmark", "round-status"]:
            path = brokers / name
            path.write_text(fixture)
            path.chmod(0o700)
        value = {"schema":"managed-completion-v2", "decision":decision,
                 "outcome":"passed" if decision == "pass" else "unmeasurable",
                 "reason_code":"passed" if decision == "pass" else "measurement_missing",
                 "reason":"Original source-bound completion result", "evidence_sha256":"a"*64}
        expected = (" \n" + json.dumps(value, indent=2) + "\n\n").encode()
        answer.write_bytes(expected)
        stage = root / operation_id
        stage.mkdir(mode=0o700)
        info = self.loop.stat()
        command_hash = hashlib.sha256(command.read_bytes()).hexdigest()
        descriptor = {"schema":"managed-round-operation-v2", "job_id":"main-hook-completion",
                      "operation_id":stage.name, "round":0, "project_root":str(self.task),
                      "loop_dir":str(self.loop), "loop_dev":info.st_dev, "loop_ino":info.st_ino,
                      "benchmark_program":str(brokers / "benchmark"),
                      "status_program":str(brokers / "round-status"), "command_sha256":command_hash}
        (stage / "operation.json").write_text(json.dumps(descriptor))
        (stage / "operation.json").chmod(0o600)
        # Same real strict metadata checks as the protected adapter, even when
        # the peer's default umask would make fixture directories writable.
        for parent in [self.task, root]:
            for path in parent.rglob("*"):
                if not path.is_symlink():
                    path.chmod(path.stat().st_mode & 0o777 & ~0o022)
        additions = {
            "HUMANIZE_MANAGED_PIPELINE":"v2", "KERNAUT_WORKFLOW_JOB_ID":"main-hook-completion",
            "HUMANIZE_COMPLETION_VALIDATOR":str(brokers / "completion"),
            "HUMANIZE_BENCHMARK_PROGRAM_V2":str(brokers / "benchmark"),
            "HUMANIZE_ROUND_STATUS":str(brokers / "round-status"),
            "HUMANIZE_MANAGED_ROUND_RECEIPT_V2":str(stage / "round-status.json"),
            "HUMANIZE_BENCHMARK_COMMAND_SHA256_V2":command_hash,
            "COMPLETION_FIXTURE_TRACE":str(trace), "COMPLETION_FIXTURE_ANSWER":str(answer),
        }
        return additions, stage, trace, answer, expected

    def test_v2_main_stop_completion_supplies_context_and_commits_before_terminal_rename(self):
        additions, stage, trace, _, expected = self.prepare_v2_completion()
        before = self.native_files()
        result = self.run_hook(self.new, additions)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"Finalize Phase complete", result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["completion"])
        self.assertEqual((stage / "completion-status.json").read_bytes(), expected)
        self.assertEqual(stat.S_IMODE((stage / "completion-status.json").stat().st_mode), 0o600)
        self.assertFalse((stage / "round-status.json").exists())
        terminal = dict(before)
        terminal["complete-state.md"] = terminal.pop("finalize-state.md")
        self.assertEqual(self.native_files(), terminal)

    def test_v2_main_stop_nonprivate_finalize_pass_enters_methodology(self):
        additions, stage, trace, _, expected = self.prepare_v2_completion(privacy=False)
        before = self.native_files()
        result = self.run_hook(self.new, additions)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["decision"], "block")
        self.assertIn(b"Finalize Phase complete", result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["completion"])
        self.assertEqual((stage / "completion-status.json").read_bytes(), expected)
        self.assertEqual(stat.S_IMODE((stage / "completion-status.json").stat().st_mode), 0o600)
        self.assertFalse((stage / "round-status.json").exists())
        transitioned = dict(before)
        transitioned["methodology-analysis-state.md"] = transitioned.pop("finalize-state.md")
        transitioned[".methodology-exit-reason"] = b"complete\n"
        transitioned["methodology-analysis-done.md"] = b""
        self.assertEqual(self.native_files(), transitioned)

    def test_v2_main_stop_methodology_completion_uses_new_operation_then_completes(self):
        first_env, first_stage, first_trace, _, first_bytes = self.prepare_v2_completion(privacy=False)
        first = self.run_hook(self.new, first_env)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["decision"], "block")
        self.assertEqual(first_trace.read_text().splitlines(), ["completion"])
        self.assertEqual((first_stage / "completion-status.json").read_bytes(), first_bytes)
        self.assertTrue((self.loop / "methodology-analysis-state.md").is_file())
        self.assertEqual((self.loop / ".methodology-exit-reason").read_bytes(), b"complete\n")
        (self.loop / "methodology-analysis-done.md").write_text("Completed fixture analysis\n")
        (self.loop / "methodology-analysis-report.md").write_text("# Fixture methodology report\n")

        additions, stage, trace, answer, _ = self.stage_v2_completion(
            operation_id="01ARZ3NDEKTSV4RRFFQ69G5FAW")
        changed = dict(json.loads(answer.read_bytes()), evidence_sha256="b"*64,
                       reason="Fresh methodology completion for the next Stop gate")
        expected = (" \n" + json.dumps(changed, indent=2) + "\n\n").encode()
        answer.write_bytes(expected)
        self.assertNotEqual(stage.name, first_stage.name)
        self.assertNotEqual(expected, first_bytes)
        self.assertEqual(json.loads((stage / "operation.json").read_bytes())["round"], 0)
        before = self.native_files()
        self.assertIn(b"current_round: 0\n", before["methodology-analysis-state.md"])
        result = self.run_hook(self.new, additions)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"Methodology analysis complete", result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["completion"])
        self.assertEqual(first_trace.read_text().splitlines(), ["completion"])
        self.assertEqual((stage / "completion-status.json").read_bytes(), expected)
        self.assertEqual((first_stage / "completion-status.json").read_bytes(), first_bytes)
        self.assertEqual(stat.S_IMODE((stage / "completion-status.json").stat().st_mode), 0o600)
        self.assertFalse((stage / "round-status.json").exists())
        terminal = dict(before)
        terminal["complete-state.md"] = terminal.pop("methodology-analysis-state.md")
        terminal.pop(".methodology-exit-reason")
        self.assertEqual(self.native_files(), terminal)

    def test_v2_main_stop_replays_original_completion_bytes_and_disposition(self):
        additions, stage, trace, answer, expected = self.prepare_v2_completion("pause")
        before = self.native_files()
        inodes = {p.name:p.stat().st_ino for p in self.loop.iterdir() if p.is_file()}
        first = self.run_hook(self.new, additions)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(first.stdout)["managed_v2_decision"], "pause")
        changed = dict(json.loads(expected), outcome="passed", decision="pass", reason_code="passed",
                       evidence_sha256="b"*64, reason="Must not replace the committed original")
        answer.write_text(json.dumps(changed))
        second = self.run_hook(self.new, additions)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.assertEqual(trace.read_text().splitlines(), ["completion"])
        self.assertEqual((stage / "completion-status.json").read_bytes(), expected)
        self.assertEqual(self.native_files(), before)
        self.assertEqual({p.name:p.stat().st_ino for p in self.loop.iterdir() if p.is_file()}, inodes)

    def test_v2_main_stop_missing_completion_helper_or_operation_context_preserves_loop(self):
        additions, stage, trace, _, _ = self.prepare_v2_completion()
        before = self.native_files()
        descriptor = (stage / "operation.json").read_bytes()
        for missing in ["helper", "descriptor", "job"]:
            with self.subTest(missing=missing):
                self.install_product("HEAD")
                (stage / "operation.json").write_bytes(descriptor)
                (stage / "operation.json").chmod(0o600)
                environment = dict(additions)
                if missing == "helper":
                    (self.plugin / "scripts/run-round-benchmark-v2.py").unlink()
                elif missing == "descriptor":
                    (stage / "operation.json").unlink()
                else:
                    environment["KERNAUT_WORKFLOW_JOB_ID"] = ""
                result = self.run_hook(self.new, environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["managed_v2_error"], "invalid_receipt")
                self.assertFalse(trace.exists())
                self.assertFalse((stage / "completion-status.json").exists())
                self.assertEqual(self.native_files(), before)

    def test_v2_main_stop_predeclared_repair_paths_distinguish_unavailable_from_unresolved(self):
        for shape in ["missing", "directory", "symlink", "missing-plan", "invalid-tuple"]:
            with self.subTest(shape=shape):
                additions, stage, trace, answer, _ = self.prepare_v2_completion()
                value = dict(json.loads(answer.read_bytes()), decision="repair", outcome="target_not_met",
                             reason_code="target_not_met")
                answer.write_text(json.dumps(value))
                expected = answer.read_bytes()
                plan = stage / "repair-plan.json"
                intent = stage / "repair-intent.json"
                plan.write_text("{}\n")
                plan.chmod(0o600)
                if shape == "directory":
                    intent.mkdir(mode=0o700)
                elif shape == "symlink":
                    intent.symlink_to(plan)
                elif shape in ["missing-plan", "invalid-tuple"]:
                    intent.write_text("{}\n")
                    intent.chmod(0o600)
                    if shape == "missing-plan":
                        plan.unlink()
                additions.update(HUMANIZE_MANAGED_REPAIR_PLAN_V2=str(plan),
                                 HUMANIZE_MANAGED_REPAIR_INTENT_V2=str(intent),
                                 HUMANIZE_MANAGED_REPAIR_OPERATION_V2=stage.name)
                before = self.native_files()
                result = self.run_hook(self.new, additions)
                self.assertEqual(result.returncode, 0, result.stderr)
                unresolved = shape in ["missing-plan", "invalid-tuple"]
                self.assertEqual(json.loads(result.stdout)["managed_v2_error"],
                                 "repair_unresolved" if unresolved else "repair_unavailable")
                self.assertEqual(b"Native v2 operation unresolved" in result.stderr, unresolved)
                self.assertEqual(trace.read_text().splitlines(), ["completion"])
                self.assertEqual((stage / "completion-status.json").read_bytes(), expected)
                self.assertFalse((stage / "round-status.json").exists())
                self.assertEqual(self.native_files(), before)
                # Re-create only the fixture's initial lifecycle for the next
                # independent gate; no accepted repair transition occurred.
                (self.loop / "state.md").write_bytes(self.state)

    def test_legacy_full_hook_benchmark_finalize_methodology_and_maxiter_match(self):
        bin_dir = self.task / "fixture-bin"
        bin_dir.mkdir()
        fixture = """#!/usr/bin/python3
import json, os, pathlib, sys
kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"kind":kind,"argv":args,"stdin":sys.stdin.read() if kind == "codex" and "-" in args else ""}
with open(os.environ["NATIVE_FIXTURE_TRACE"], "a") as stream:
    stream.write(json.dumps(record, sort_keys=True) + "\\n")
if kind == "completion":
    print(json.dumps({"schema":"managed-completion-v1","decision":"pass","reason":"Fixture verified","evidence_sha256":"a"*64}))
elif kind == "round-status":
    print(json.dumps({"decision":"unknown" if os.environ.get("NATIVE_FIXTURE_BAD_STATUS") else "continue","reason":"Fixture status"}))
elif "--help" in args:
    print("fixture help")
elif "review" in args:
    print("No issues found")
else:
    print("Mainline Progress Verdict: ADVANCED\\nReviewed fixture\\nCOMPLETE")
"""
        for name in ["codex", "completion", "round-status"]:
            path = bin_dir / name
            path.write_text(fixture)
            path.chmod(0o755)
        date = bin_dir / "date"
        # A local PATH fixture, not a production clock or output normalization.
        date.write_text("#!/bin/sh\nexec /bin/date --date=@1794096000 \"$@\"\n")
        date.chmod(0o755)
        trace = Path(self.tmp.name) / "native-trace"
        additions = {"PATH":str(bin_dir) + os.pathsep + self.env["PATH"],
                     "NATIVE_FIXTURE_TRACE":str(trace),
                     "HUMANIZE_COMPLETION_VALIDATOR":str(bin_dir / "completion"),
                     "HUMANIZE_ROUND_STATUS":str(bin_dir / "round-status")}
        initial = self.state.replace(b"deadbeef", subprocess.check_output(
            ["git", "-C", str(self.task), "rev-parse", "HEAD"]).strip())
        product_paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", BASE], cwd=ROOT, text=True).splitlines()
        for path in product_paths:
            if path.startswith(("hooks/", "scripts/", "assets/", "templates/")) and path != "hooks/loop-codex-stop-hook.sh":
                old = subprocess.check_output(["git", "show", BASE + ":" + path], cwd=ROOT)
                head = subprocess.check_output(["git", "show", self.head + ":" + path], cwd=ROOT)
                self.assertEqual(head, old, path)
                self.assertEqual((ROOT / path).read_bytes(), head, path)
        added = subprocess.check_output(["git", "diff", "--name-only", "--diff-filter=A", BASE, self.head,
                                         "--", "hooks", "scripts", "assets", "templates"], cwd=ROOT, text=True).splitlines()
        self.assertEqual(set(added), {"hooks/lib/managed-completion-v2.sh", "scripts/apply-managed-repair-v2.py",
                                     "scripts/prepare-managed-repair-v2.sh", "scripts/run-round-benchmark-v2.sh",
                                     "scripts/run-round-benchmark-v2.py"})
        print("HOOK_COMPAT_BYTES", hashlib.sha256(self.new).hexdigest(),
              "BASE", BASE, "HEAD", self.head)
        cases = [("benchmark", True), ("finalize", True), ("finalize", False),
                 ("methodology", True), ("maxiter", True), ("maxiter", False), ("invalid-status", True)]
        for phase, privacy in cases:
            for managed in [False, True]:
                if phase == "invalid-status" and not managed:
                    continue
                with self.subTest(phase=phase, managed=managed, privacy=privacy):
                    shutil.rmtree(self.loop)
                    self.loop.mkdir()
                    shutil.rmtree(self.task / "cache", ignore_errors=True)
                    shutil.copyfile(self.task / "plan.md", self.loop / "plan.md")
                    name = {"finalize":"finalize-state.md", "methodology":"methodology-analysis-state.md"}.get(phase, "state.md")
                    state = initial.replace(b"current_round: 0", b"current_round: 5") if phase == "maxiter" else initial
                    state = state.replace(b"agent_teams: false\n", b"agent_teams: false\nprivacy_mode: " + (b"true" if privacy else b"false") + b"\n")
                    (self.loop / name).write_bytes(state)
                    for filename, text in {
                        "round-0-summary.md":"# Fixture summary\nCompleted local work.\n",
                        "finalize-summary.md":"# Fixture final summary\n",
                        "benchmark-command.sh":"printf 'full benchmark fixture\\n'\n",
                        "benchmark-timeout":"5\n",
                    }.items():
                        (self.loop / filename).write_text(text)
                    if phase == "methodology":
                        (self.loop / "methodology-analysis-done.md").write_text("Done\n")
                        (self.loop / "methodology-analysis-report.md").write_text("# Local analysis\n")
                        (self.loop / ".methodology-exit-reason").write_text("complete\n")
                    if phase == "maxiter":
                        (self.loop / "round-5-summary.md").write_text("# Budget boundary\n")
                    env = dict(additions)
                    if managed:
                        env["HUMANIZE_MANAGED_RELIABILITY_V1"] = "1"
                    if phase == "invalid-status":
                        env["NATIVE_FIXTURE_BAD_STATUS"] = "1"
                    before = self.tree_snapshot()
                    loop_before = set(self.native_files())
                    trace.unlink(missing_ok=True)
                    self.install_product(BASE)
                    self.restore_tree(before)
                    old = self.run_hook(self.old, env)
                    old_files = self.native_files()
                    old_tree = self.tree_snapshot()
                    records = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
                    old_trace = trace.read_bytes() if trace.exists() else b""
                    self.assertEqual(old.returncode, 0, old.stderr)
                    tags = [item["kind"] for item in records]
                    expected_tags = {
                        "benchmark": (["round-status"] if managed else []) + ["codex", "codex", "codex"],
                        "finalize": ["completion"] if managed else [],
                        "methodology": ["completion"] if managed else [],
                        "maxiter": [], "invalid-status":["round-status"],
                    }[phase]
                    self.assertEqual(tags, expected_tags, (phase, old.stdout, old.stderr, sorted(old_files)))
                    if phase in ["finalize", "maxiter"]:
                        self.assertNotIn(name, old_files)
                        if privacy:
                            terminal = "maxiter-state.md" if phase == "maxiter" else "complete-state.md"
                            self.assertEqual(old.stdout, b"")
                            self.assertEqual(old_files[terminal], state)
                            expected_files = loop_before - {name} | {terminal}
                        else:
                            self.assertEqual(old_files["methodology-analysis-state.md"], state)
                            self.assertEqual(old_files[".methodology-exit-reason"], b"maxiter\n" if phase == "maxiter" else b"complete\n")
                            self.assertEqual(json.loads(old.stdout)["decision"], "block")
                            expected_files = loop_before - {name} | {"methodology-analysis-state.md", ".methodology-exit-reason", "methodology-analysis-done.md"}
                    elif phase == "methodology":
                        self.assertEqual(old.stdout, b"")
                        self.assertNotIn(name, old_files)
                        self.assertEqual(old_files["complete-state.md"], state)
                        expected_files = loop_before - {name, ".methodology-exit-reason"} | {"complete-state.md"}
                    elif phase == "invalid-status":
                        self.assertEqual(json.loads(old.stdout)["platform_blocked"], True)
                        self.assertEqual(json.loads(old.stdout)["decision"], "block")
                        self.assertEqual(old_files["state.md"], state)
                        expected_files = loop_before | {"round-0-benchmark.log", "round-0-benchmark.md"}
                    else:
                        self.assertEqual(json.loads(old.stdout)["decision"], "block")
                        self.assertIn("finalize-state.md", old_files)
                        self.assertNotIn("state.md", old_files)
                        self.assertTrue(any(item["stdin"] for item in records if "exec" in item["argv"]))
                        expected_files = loop_before - {"state.md"} | {"finalize-state.md", ".review-phase-started", "round-0-benchmark.log", "round-0-benchmark.md", "round-0-review-prompt.md", "round-0-review-result.md", "round-1-review-prompt.md"}
                    if managed and phase in ["finalize", "methodology"]:
                        expected_files.add("round-0-completion-validation.json")
                    self.assertEqual(set(old_files), expected_files)
                    self.restore_tree(before)
                    trace.unlink(missing_ok=True)
                    self.install_product("HEAD")
                    time.sleep(1.1)
                    new = self.run_hook(self.new, env)
                    self.assertEqual((new.returncode, new.stdout, new.stderr), (old.returncode, old.stdout, old.stderr))
                    self.assertEqual(self.tree_snapshot(), old_tree)
                    self.assertEqual(trace.read_bytes() if trace.exists() else b"", old_trace)

    def test_missing_nonexecutable_or_wrong_v2_resources_never_fall_back(self):
        library = self.plugin / "hooks/lib/managed-completion-v2.sh"
        runner = self.plugin / "scripts/run-round-benchmark-v2.sh"
        before = self.native_files()
        cases = [(False, False, 0o755, "missing_v2_runtime"),
                 (True, True, 0o644, "missing_v2_runtime"),
                 (True, True, 0o755, "invalid_v2_runtime")]
        for have_lib, have_runner, mode, code in cases:
            with self.subTest(code=code, mode=mode):
                library.unlink(missing_ok=True)
                runner.unlink(missing_ok=True)
                if have_lib:
                    library.write_text("# Deliberate resource-shape fixture, not a native implementation\ntrue\n")
                    library.chmod(mode)
                if have_runner:
                    runner.write_text("#!/bin/sh\nexit 99\n")
                    runner.chmod(0o755)
                result = self.run_hook(self.new, {"HUMANIZE_MANAGED_PIPELINE": "v2"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["managed_v2_error"], code)
                self.assertEqual(self.native_files(), before)


if __name__ == "__main__":
    unittest.main()
