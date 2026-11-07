"""Actual main-hook dispatch tests; no model, device, or business execution."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = "d920d5d"


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

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="dispatch-task-")
        self.addCleanup(tmp.cleanup)
        self.task = Path(tmp.name)
        self.env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.task), XDG_CACHE_HOME=str(self.task / "cache"))
        self.env.pop("HUMANIZE_MANAGED_PIPELINE", None)
        self.env.pop("HUMANIZE_MANAGED_RELIABILITY_V1", None)
        subprocess.run(["git", "init", "-q", "--initial-branch=main", str(self.task)], check=True)
        for key, value in [("user.email", "fixture@example.invalid"), ("user.name", "Fixture")]:
            subprocess.run(["git", "-C", str(self.task), "config", key, value], check=True)
        (self.task / "plan.md").write_text("# Plan\n\nPreserve the original native loop.\n")
        subprocess.run(["git", "-C", str(self.task), "add", "plan.md"], check=True)
        subprocess.run(["git", "-C", str(self.task), "commit", "-qm", "fixture"], check=True)
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
