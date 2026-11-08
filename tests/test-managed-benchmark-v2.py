"""Actual isolated Native runner with local fixed-broker fixtures only.

No Node authorization, real benchmark, model, device, or release is tested.
"""
import hashlib
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
OPERATION = "01ARZ3NDEKTSV4RRFFQ69G5FAV"


class BenchmarkRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="managed-benchmark-v2-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.plugin = self.root / "plugin"
        (self.plugin / "scripts").mkdir(parents=True)
        for name in ["run-round-benchmark-v2.sh", "run-round-benchmark-v2.py",
                     "apply-managed-repair-v2.py", "validate-managed-receipt-v2.py"]:
            shutil.copyfile(ROOT / "scripts" / name, self.plugin / "scripts" / name)
            (self.plugin / "scripts" / name).chmod(0o755)
        self.project = self.root / "project"
        self.loop = self.project / ".humanize/rlcr/native-loop"
        self.loop.mkdir(parents=True)
        (self.project / "solution.py").write_text("original candidate\n")
        (self.loop / "state.md").write_text("---\ncurrent_round: 2\nmax_iterations: 5\n---\n")
        self.command = self.loop / "benchmark-command.sh"
        self.command.write_text("fixed command bytes selected by Node\n")
        self.stage = self.root / "operations" / OPERATION
        self.stage.mkdir(parents=True, mode=0o700)
        self.trace = self.root / "trace"
        self.answer = self.root / "broker-status.json"
        self.fixture_bin = self.root / "broker-bin"
        self.fixture_bin.mkdir()
        code = '''#!/usr/bin/python3.12 -I
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["BENCHMARK_FIXTURE_TRACE"], "a") as stream:
    stream.write(name + "\\n")
if os.environ.get("BENCHMARK_FIXTURE_FAIL") == name:
    raise SystemExit(7)
if name == "benchmark":
    if os.environ.get("BENCHMARK_FIXTURE_BAD_UTF8"):
        sys.stdout.buffer.write(b"\\xff")
        raise SystemExit(0)
    print("Local broker display summary, not full measurement")
    if os.environ.get("BENCHMARK_FIXTURE_OVERSIZE"):
        print("x" * (128*1024))
else:
    sys.stdout.buffer.write(pathlib.Path(os.environ["BENCHMARK_FIXTURE_STATUS"]).read_bytes())
'''
        for name in ["benchmark", "round-status"]:
            path = self.fixture_bin / name
            path.write_text(code)
            path.chmod(0o700)
        self.env = {key:value for key,value in os.environ.items() if not key.startswith("HUMANIZE_")}
        self.env.update(
            HUMANIZE_MANAGED_PIPELINE="v2", KERNAUT_WORKFLOW_JOB_ID="original-job",
            HUMANIZE_BENCHMARK_PROGRAM_V2=str(self.fixture_bin / "benchmark"),
            HUMANIZE_ROUND_STATUS=str(self.fixture_bin / "round-status"),
            HUMANIZE_MANAGED_ROUND_RECEIPT_V2=str(self.stage / "round-status.json"),
            HUMANIZE_BENCHMARK_COMMAND_SHA256_V2=hashlib.sha256(self.command.read_bytes()).hexdigest(),
            BENCHMARK_FIXTURE_TRACE=str(self.trace), BENCHMARK_FIXTURE_STATUS=str(self.answer))
        info = self.loop.stat()
        self.operation = {
            "schema":"managed-round-operation-v2", "job_id":"original-job", "operation_id":OPERATION,
            "round":2, "project_root":str(self.project), "loop_dir":str(self.loop),
            "loop_dev":info.st_dev, "loop_ino":info.st_ino,
            "benchmark_program":self.env["HUMANIZE_BENCHMARK_PROGRAM_V2"],
            "status_program":self.env["HUMANIZE_ROUND_STATUS"],
            "command_sha256":self.env["HUMANIZE_BENCHMARK_COMMAND_SHA256_V2"]}
        (self.stage / "operation.json").write_text(json.dumps(self.operation))
        self.receipt = {"schema":"managed-round-status-v2", "outcome":"passed", "decision":"continue",
                        "reason_code":"passed", "reason":"Original fixed broker result", "evidence_sha256":"a"*64}
        self.answer.write_text(json.dumps(self.receipt) + "\n")
        # The host's shared umask may create group-writable fixtures. Exercise
        # the real strict guard with supervisor-owned, protected resources.
        for path in self.root.rglob("*"):
            path.chmod(path.stat().st_mode & 0o777 & ~0o022)

    def command_line(self):
        return [str(self.plugin / "scripts/run-round-benchmark-v2.sh"),
                "--project-root", str(self.project), "--loop-dir", str(self.loop),
                "--round", "2", "--command-file", str(self.command), "--timeout", "5"]

    def tearDown(self):
        self.assertEqual(list(self.loop.glob(".managed-benchmark-v2-*")), [])

    def loaded_publisher(self):
        path = self.plugin / "scripts/run-round-benchmark-v2.py"
        module = types.ModuleType("native_publication_fixture")
        module.__file__ = str(path)
        exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
        fs = module.load("native_fs_fixture", "scripts/apply-managed-repair-v2.py")
        return module, fs

    def run_runner(self, additions=None):
        return subprocess.run(self.command_line(), env=dict(self.env, **(additions or {})),
                              cwd=self.root, capture_output=True, timeout=10)

    def calls(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def native_files(self):
        return {str(path.relative_to(self.project)):(path.read_bytes(), path.stat().st_mode & 0o777)
                for path in self.project.rglob("*") if path.is_file()}

    def test_continue_and_retry_use_one_broker_operation_and_preserve_native_state(self):
        original = (self.loop / "state.md").read_bytes()
        first = self.run_runner()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, b"")
        before = self.native_files()
        files = [self.loop / ("round-2-benchmark." + suffix) for suffix in ["log", "md"]]
        inodes = [path.stat().st_ino for path in files]
        self.assertIn(b"bounded display summary", files[1].read_bytes())
        self.assertEqual((self.loop / "state.md").read_bytes(), original)
        second = self.run_runner()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.native_files(), before)
        self.assertEqual([path.stat().st_ino for path in files], inodes)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_pause_and_owner_repair_preserve_every_native_file_and_replay_no_callback(self):
        for code, decision in [("measurement_missing", "pause"), ("owner_requested_repair", "repair")]:
            with self.subTest(decision=decision):
                self.receipt.update(outcome="unmeasurable", decision=decision, reason_code=code)
                self.answer.write_text(json.dumps(self.receipt))
                for path in self.stage.glob("*.txt"):
                    path.unlink()
                (self.stage / "round-status.json").unlink(missing_ok=True)
                self.trace.unlink(missing_ok=True)
                # Existing native artifacts do not imply the current operation
                # has been measured, and a pause may not replace them.
                (self.loop / "round-2-benchmark.md").write_text("Original older native artifact\n")
                (self.loop / "round-2-benchmark.log").write_text("Original older log\n")
                before = self.native_files()
                for _ in range(2):
                    result = self.run_runner()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(self.native_files(), before)
                self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_candidate_failure_is_a_continue_receipt_not_a_transport_exit(self):
        self.receipt.update(outcome="correctness_failed", reason_code="candidate_error")
        self.answer.write_text(json.dumps(self.receipt))
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"correctness_failed", (self.loop / "round-2-benchmark.md").read_bytes())

    def test_preexisting_invalid_md_after_log_publication_recovers_from_staging(self):
        md = self.loop / "round-2-benchmark.md"
        md.mkdir()  # Metadata rejection for .md, after .log has committed.
        failed = self.run_runner()
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue((self.loop / "round-2-benchmark.log").is_file())
        md.rmdir()  # Explicit local reconciliation, not an automatic Node retry.
        restored = self.run_runner()
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertTrue(md.is_file())
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_concurrent_same_operation_is_serialized_and_calls_each_broker_once(self):
        children = [subprocess.Popen(self.command_line(), env=self.env, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, cwd=self.root) for _ in range(6)]
        try:
            results = [(child.communicate(timeout=15), child.returncode) for child in children]
            for ((stdout, stderr), code) in results:
                self.assertEqual(code, 0, stderr)
                self.assertEqual(stdout, b"")
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
                child.stdout.close()
                child.stderr.close()
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_modes_and_original_command_are_checked_before_any_callback(self):
        before = self.native_files()
        for additions in [{"HUMANIZE_MANAGED_PIPELINE":""}, {"HUMANIZE_MANAGED_PIPELINE":"v3"},
                          {"HUMANIZE_MANAGED_RELIABILITY_V1":""}]:
            self.assertNotEqual(self.run_runner(additions).returncode, 0)
            self.assertEqual(self.calls(), [])
            self.assertEqual(self.native_files(), before)
        self.command.write_text("replacement command\n")
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_status_and_broker_failure_never_publish_native_files(self):
        before = self.native_files()
        self.answer.write_text('{"schema":"managed-round-status-v2","decision":"continue"}')
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.native_files(), before)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])
        self.assertFalse((self.stage / "round-status.json").exists())
        self.trace.unlink()
        (self.stage / "benchmark-summary.txt").unlink()
        self.assertNotEqual(self.run_runner({"BENCHMARK_FIXTURE_FAIL":"benchmark"}).returncode, 0)
        self.assertEqual(self.calls(), ["benchmark"])
        self.assertEqual(self.native_files(), before)

    def test_conflicting_native_artifact_is_not_overwritten(self):
        target = self.loop / "round-2-benchmark.log"
        target.write_text("conflicting existing bytes\n")
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "conflicting existing bytes\n")
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_wrong_operation_and_aliases_are_rejected(self):
        original = self.stage / "operation.json"
        self.operation["round"] = 3
        original.write_text(json.dumps(self.operation))
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.calls(), [])

        self.operation["round"] = 2
        original.write_text(json.dumps(self.operation))
        alias = self.root / "operation-alias"
        os.link(original, alias)
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_summary_commits_before_status_and_retry_only_requests_original_status(self):
        failed = self.run_runner({"BENCHMARK_FIXTURE_FAIL":"round-status"})
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue((self.stage / "benchmark-summary.txt").is_file())
        self.assertFalse((self.stage / "round-status.json").exists())
        restored = self.run_runner()
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertEqual(self.calls(), ["benchmark", "round-status", "round-status"])

    def test_cached_receipt_symlink_is_rejected_before_any_replayed_callback(self):
        first = self.run_runner()
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.native_files()
        path = self.stage / "round-status.json"
        path.unlink()
        path.symlink_to(self.answer)
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.native_files(), before)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_status_program_and_stage_location_are_bound_before_callbacks(self):
        alternate = self.fixture_bin / "other-status"
        shutil.copyfile(self.fixture_bin / "round-status", alternate)
        alternate.chmod(0o700)
        self.assertNotEqual(self.run_runner({"HUMANIZE_ROUND_STATUS":str(alternate)}).returncode, 0)
        self.assertEqual(self.calls(), [])
        inside = self.project / OPERATION
        inside.mkdir(mode=0o700)
        shutil.copyfile(self.stage / "operation.json", inside / "operation.json")
        self.assertNotEqual(self.run_runner({"HUMANIZE_MANAGED_ROUND_RECEIPT_V2":str(inside / "round-status.json")}).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_stage_and_cached_file_modes_are_strict(self):
        for mode in [0o750, 0o711]:
            self.stage.chmod(mode)
            self.assertNotEqual(self.run_runner().returncode, 0)
            self.assertEqual(self.calls(), [])
        self.stage.chmod(0o700)
        self.assertEqual(self.run_runner().returncode, 0)
        for name in ["round-status.json", "benchmark-summary.txt"]:
            path = self.stage / name
            path.chmod(0o644)
            self.assertNotEqual(self.run_runner().returncode, 0)
            path.chmod(0o600)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_receipt_without_summary_is_unknown_and_cannot_replay_benchmark(self):
        self.assertEqual(self.run_runner().returncode, 0)
        (self.stage / "benchmark-summary.txt").unlink()
        before = self.native_files()
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.native_files(), before)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])

    def test_bad_utf8_unknown_decision_and_argument_abbreviation_are_rejected(self):
        self.assertNotEqual(self.run_runner({"BENCHMARK_FIXTURE_BAD_UTF8":"1"}).returncode, 0)
        self.assertEqual(self.calls(), ["benchmark"])
        self.trace.unlink()
        self.receipt["decision"] = "future_decision"
        self.answer.write_text(json.dumps(self.receipt))
        self.assertNotEqual(self.run_runner().returncode, 0)
        self.assertEqual(self.calls(), ["benchmark", "round-status"])
        self.trace.unlink()
        args = self.command_line()
        args[1] = "--proj"
        result = subprocess.run(args, env=self.env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_anonymous_publication_handles_link_failure_and_eexist_races(self):
        module, fs = self.loaded_publisher()
        fd = fs.directory(self.loop)
        try:
            with mock.patch.object(module.os, "link", side_effect=OSError(errno.EIO, "injected link failure")):
                with self.assertRaises(OSError):
                    module.publish(fs, fd, "link-error.md", b"expected")
            self.assertFalse((self.loop / "link-error.md").exists())
            for equal in [True, False]:
                name = "equal-race.md" if equal else "different-race.md"
                expected = b"expected"
                actual = expected if equal else b"conflicting"

                def another_publisher(*args, **kwargs):
                    target = self.loop / name
                    target.write_bytes(actual)
                    target.chmod(0o600)
                    raise FileExistsError(errno.EEXIST, "injected concurrent publisher")

                with mock.patch.object(module.os, "link", side_effect=another_publisher):
                    if equal:
                        module.publish(fs, fd, name, expected)
                    else:
                        with self.assertRaises(ValueError):
                            module.publish(fs, fd, name, expected)
                self.assertEqual((self.loop / name).read_bytes(), actual)
        finally:
            os.close(fd)

    def test_sigkill_before_anonymous_inode_link_leaves_no_named_file(self):
        script = '''import os, pathlib, signal, sys, types
path = pathlib.Path(sys.argv[1])
module = types.ModuleType("native_crash_fixture"); module.__file__ = str(path)
exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
fs = module.load("native_crash_fs", "scripts/apply-managed-repair-v2.py")
fd = fs.directory(pathlib.Path(sys.argv[2]))
def stop_before_link(*args, **kwargs):
    os.kill(os.getpid(), signal.SIGKILL)
module.os.link = stop_before_link
module.publish(fs, fd, "must-not-appear.md", b"fully written anonymous bytes")
'''
        before = self.native_files()
        result = subprocess.run(["/usr/bin/python3.12", "-I", "-S", "-B", "-c", script,
                                 str(self.plugin / "scripts/run-round-benchmark-v2.py"), str(self.loop)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, -9, result.stderr)
        self.assertEqual(self.native_files(), before)

    def test_oversized_summary_is_a_runtime_error_not_a_native_pause(self):
        before = self.native_files()
        result = self.run_runner({"BENCHMARK_FIXTURE_OVERSIZE":"1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(self.native_files(), before)
        self.assertEqual(self.calls(), ["benchmark"])


if __name__ == "__main__":
    unittest.main()
