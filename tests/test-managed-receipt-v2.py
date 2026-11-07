"""Pure wire tests, including the actual isolated decoder process. No devices/models."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/validate-managed-receipt-v2.py"
SPEC = importlib.util.spec_from_file_location("receipt_v2", SCRIPT)
CODEC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CODEC)


def receipt(phase="completion", outcome="passed", decision="pass", code="passed"):
    return {
        "schema": "managed-round-status-v2" if phase == "round" else "managed-completion-v2",
        "outcome": outcome, "decision": decision, "reason_code": code,
        "reason": "Original source-bound evidence; no additional execution authorized.",
        "evidence_sha256": "a" * 64,
    }


class ReceiptTests(unittest.TestCase):
    def decode(self, value, phase="completion"):
        return CODEC.decode(json.dumps(value).encode(), phase)

    def test_normal_round_continue_cannot_be_used_as_terminal_pass(self):
        for outcome, code in [
            ("passed", "passed"), ("target_not_met", "target_not_met"),
            ("correctness_failed", "correctness_failed"),
            ("correctness_failed", "candidate_error"), ("invalid_result", "invalid_result"),
        ]:
            with self.subTest(outcome=outcome, code=code):
                value = receipt("round", outcome, "continue", code)
                self.assertEqual(self.decode(value, "round"), value)
                with self.assertRaises(ValueError): self.decode(value)
                value["schema"] = "managed-completion-v2"
                with self.assertRaises(ValueError): self.decode(value)

    def test_completion_requires_passed_or_bounded_negative_disposition(self):
        self.decode(receipt())
        for outcome, code in [("target_not_met", "target_not_met"), ("correctness_failed", "correctness_failed"), ("invalid_result", "invalid_result"), ("acceptance_not_met", "acceptance_not_met")]:
            self.decode(receipt(outcome=outcome, decision="repair", code=code))
            with self.assertRaises(ValueError): self.decode(receipt(outcome=outcome, decision="pass", code=code))

    def test_capacity_is_unmeasurable_and_platform_reference_never_repair(self):
        for phase in ["round", "completion"]:
            for code in ["measurement_missing", "raw_limit", "report_limit", "output_limit"]:
                self.decode(receipt(phase, "unmeasurable", "pause", code), phase)
                with self.assertRaises(ValueError): self.decode(receipt(phase, "platform_blocked", "pause", code), phase)
            for outcome in ["platform_blocked", "reference_blocked", "invalid_spec"]:
                self.decode(receipt(phase, outcome, "pause", outcome), phase)
                for code in [outcome, "owner_requested_repair"]:
                    with self.assertRaises(ValueError): self.decode(receipt(phase, outcome, "repair", code), phase)

    def test_owner_repair_is_a_bidirectional_exact_tuple_not_an_authority_token(self):
        for phase in ["round", "completion"]:
            self.decode(receipt(phase, "unmeasurable", "repair", "owner_requested_repair"), phase)
            for outcome, decision, code in [
                ("unmeasurable", "repair", "measurement_missing"),
                ("unmeasurable", "pause", "owner_requested_repair"),
                ("passed", "repair", "owner_requested_repair"),
                ("unmeasurable", "pass", "owner_requested_repair"),
            ]:
                with self.assertRaises(ValueError): self.decode(receipt(phase, outcome, decision, code), phase)

    def test_strict_shape_identity_bounds_and_duplicate_fields(self):
        value = receipt()
        raw = json.dumps(value)
        with self.assertRaises(ValueError): CODEC.decode((raw[:-1] + ',"decision":"pass"}').encode(), "completion")
        for key, replacement in [("schema", "managed-completion-v1"), ("decision", True), ("evidence_sha256", "A" * 64), ("reason", ""), ("reason", "\x00"), ("reason", "中" * 2731)]:
            invalid = dict(value, **{key: replacement})
            with self.assertRaises(ValueError): self.decode(invalid)
        with self.assertRaises(ValueError): self.decode(dict(value, approval=True))
        with self.assertRaises(ValueError): CODEC.decode(b" " * (CODEC.LIMIT + 1), "round")
        with self.assertRaises(ValueError): CODEC.decode(b"\xff", "round")
        for reason in ["\u001b[31m", "bad\rdisplay", "\ud800"]:
            with self.assertRaises(ValueError): self.decode(dict(value, reason=reason))
        deep=b"[" * 30000 + b"]" * 30000
        with self.assertRaises(RecursionError): json.loads(deep)
        with self.assertRaises(ValueError): CODEC.decode(deep, "round")
        for outcome,decision,code in [("passed","pass","passed"),("acceptance_not_met","repair","acceptance_not_met"),("unmeasurable","continue","measurement_missing")]:
            with self.assertRaises(ValueError): self.decode(receipt("round",outcome,decision,code),"round")

    def test_complete_allowlist_matches_the_cross_runtime_golden(self):
        golden=json.loads((ROOT/"references/managed-receipt-v2-golden.json").read_text())
        for phase in ["round","completion"]:
            expected={tuple(row) for row in golden[phase]}
            self.assertEqual(CODEC.allowed_combinations(phase),expected)
            for outcome,decision,code in expected:
                self.decode(receipt(phase,outcome,decision,code),phase)

    def test_actual_cli_ignores_task_python_poison_and_does_not_write_lifecycle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "json.py").write_text("raise RuntimeError('task poison')\n")
            state = root / "state.md"
            state.write_text("---\ncurrent_round: 5\nmax_iterations: 5\n---\n")
            before = {p.name: p.read_bytes() for p in root.iterdir()}
            env=dict(os.environ,PYTHONPATH=str(root))
            poisoned=subprocess.run([sys.executable,"-S","-B",str(SCRIPT),"--phase","completion"],input=json.dumps(receipt()).encode(),capture_output=True,cwd=root,env=env)
            self.assertNotEqual(poisoned.returncode,0)
            self.assertIn(b"task poison",poisoned.stderr)
            for valid in [True, False]:
                payload = json.dumps(receipt()).encode() if valid else b"{}"
                result = subprocess.run([sys.executable, "-I", "-S", "-B", str(SCRIPT), "--phase", "completion"], input=payload, capture_output=True, cwd=root,env=env)
                self.assertEqual(result.returncode, 0 if valid else 2, result.stderr)
                if valid: self.assertEqual(json.loads(result.stdout), receipt())
                else: self.assertEqual(result.stdout, b"")
            self.assertEqual(before, {p.name: p.read_bytes() for p in root.iterdir()})


if __name__ == "__main__":
    unittest.main()
