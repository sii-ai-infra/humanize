"""Actual v2 shell callbacks + strict decoder, with explicit broker fixtures.

No Node authorization, native budget helper, model or hardware acceptance claim.
"""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


def receipt(phase="completion",outcome="passed",decision="pass",code="passed"):
    return {"schema":"managed-completion-v2" if phase=="completion" else "managed-round-status-v2",
            "outcome":outcome,"decision":decision,"reason_code":code,"reason":"Original source-bound evidence.","evidence_sha256":"a"*64}


class CallbackTests(unittest.TestCase):
    def run_case(self,value,phase="completion",environment=None,callback_exit=0):
        temp=tempfile.TemporaryDirectory(prefix="native-v2-callback-");self.addCleanup(temp.cleanup)
        root=Path(temp.name).resolve();project=root/"project";loop=project/"loop";loop.mkdir(parents=True)
        (loop/"state.md").write_text("---\ncurrent_round: 2\nmax_iterations: 5\n---\n")
        (loop/"round-2-prompt.md").write_text("Original prompt\n")
        before={p.name:p.read_bytes() for p in loop.iterdir()}
        encoded=json.dumps(value,ensure_ascii=False)
        brokers=root/"brokers";brokers.mkdir()
        callback=brokers/"completion";callback.write_text("#!/bin/sh\ncat <<'RECEIPT'\n"+encoded+"\nRECEIPT\nexit "+str(callback_exit)+"\n");callback.chmod(0o700)
        for name in ["benchmark","round-status"]:
            path=brokers/name;path.write_text("#!/bin/sh\nexit 0\n");path.chmod(0o700)
        command=loop/"benchmark-command.sh";command.write_text("original fixed benchmark command\n")
        stage=root/"01ARZ3NDEKTSV4RRFFQ69G5FAV";stage.mkdir(mode=0o700)
        staged=stage/"round-status.json"
        if phase=="round":staged.write_text(encoded)
        info=loop.stat();command_hash=hashlib.sha256(command.read_bytes()).hexdigest()
        (stage/"operation.json").write_text(json.dumps({
            "schema":"managed-round-operation-v2","job_id":"callback-fixture","operation_id":stage.name,
            "round":2,"project_root":str(project),"loop_dir":str(loop),"loop_dev":info.st_dev,"loop_ino":info.st_ino,
            "benchmark_program":str(brokers/"benchmark"),"status_program":str(brokers/"round-status"),
            "command_sha256":command_hash}))
        (root/"json.py").write_text("raise RuntimeError('task poison imported')\n")
        env=dict(os.environ,PYTHONPATH=str(root));env.pop("HUMANIZE_MANAGED_RELIABILITY_V1",None)
        env.update(KERNAUT_WORKFLOW_JOB_ID="callback-fixture",HUMANIZE_COMPLETION_VALIDATOR=str(callback),
                   HUMANIZE_MANAGED_ROUND_RECEIPT_V2=str(staged),HUMANIZE_BENCHMARK_PROGRAM_V2=str(brokers/"benchmark"),
                   HUMANIZE_ROUND_STATUS=str(brokers/"round-status"),HUMANIZE_BENCHMARK_COMMAND_SHA256_V2=command_hash)
        env.update(environment or {})
        for path in root.rglob("*"):path.chmod(path.stat().st_mode & 0o777 & ~0o022)
        before={p.name:p.read_bytes() for p in loop.iterdir()}
        script='''set -euo pipefail
PLUGIN_ROOT="$1"; PROJECT_ROOT="$2/project"; LOOP_DIR="$PROJECT_ROOT/loop"; CURRENT_ROUND=2
export HUMANIZE_MANAGED_PIPELINE=v2
source "$1/hooks/lib/managed-completion-v2.sh"
if [[ "$3" == completion ]]; then
 if managed_completion_validation; then echo accepted >&2; else echo blocked >&2; fi
else
 if managed_round_status_validation_v2; then echo accepted >&2; else echo blocked >&2; fi
fi
'''
        result=subprocess.run(["bash","-c",script,"test",str(ROOT),str(root),phase],cwd=root,env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(before,{p.name:p.read_bytes() for p in loop.iterdir()})
        return result

    def test_machine_pass_only_authorizes_original_completion_caller(self):
        result=self.run_case(receipt());self.assertIn("accepted",result.stderr);self.assertEqual(result.stdout,"")

    def test_round_continue_is_not_terminal_completion(self):
        result=self.run_case(receipt("round","passed","continue","passed"),"round")
        self.assertIn("accepted",result.stderr);self.assertEqual(result.stdout,"")
        result=self.run_case(receipt("round","passed","pass","passed"),"round")
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"invalid_receipt")

    def test_every_pause_preserves_actual_native_state_and_budget(self):
        for outcome,code in [("unmeasurable","measurement_missing"),("unmeasurable","raw_limit"),("unmeasurable","report_limit"),("unmeasurable","output_limit"),("platform_blocked","platform_blocked"),("reference_blocked","reference_blocked"),("invalid_spec","invalid_spec")]:
            for phase in ["round","completion"]:
                with self.subTest(outcome=outcome,code=code,phase=phase):
                    result=self.run_case(receipt(phase,outcome,"pause",code),phase)
                    self.assertIn("blocked",result.stderr)
                    self.assertEqual(json.loads(result.stdout)["managed_v2_decision"],"pause")
                    self.assertEqual(json.loads(result.stdout)["managed_v2_evidence_sha256"],"a"*64)

    def test_repair_cannot_fall_through_without_fixed_native_operation(self):
        for outcome,code in [("target_not_met","target_not_met"),("unmeasurable","owner_requested_repair")]:
            result=self.run_case(receipt(outcome=outcome,decision="repair",code=code))
            self.assertIn("blocked",result.stderr)
            self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"repair_unavailable")

    def test_legacy_pass_and_conflicting_mode_never_authorize_v2(self):
        value=receipt();value["schema"]="managed-completion-v1"
        result=self.run_case(value)
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"invalid_receipt")
        result=self.run_case(receipt(),environment={"HUMANIZE_MANAGED_RELIABILITY_V1":""})
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"unsupported_mode")

    def test_failed_callback_cannot_hide_behind_a_valid_pass_document(self):
        result=self.run_case(receipt(),callback_exit=7)
        self.assertIn("blocked",result.stderr)
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"invalid_receipt")

    def test_round_repair_only_accepts_the_explicit_owner_tuple_protocol(self):
        result=self.run_case(receipt("round","target_not_met","repair","target_not_met"),"round")
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"invalid_receipt")
        result=self.run_case(receipt("round","unmeasurable","repair","owner_requested_repair"),"round")
        # Protocol recognition grants no authority. No protected prepared
        # operation/CAS means the helper remains unavailable, never continue.
        self.assertEqual(json.loads(result.stdout)["managed_v2_error"],"repair_unavailable")


if __name__=="__main__":unittest.main()
