"""Native effects and differential compatibility; plans are explicit protected
fixtures, not actual Node CAS/answer authority or business E2E.
"""
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts/apply-managed-repair-v2.py"
OP = "01K9G000000000000000000000"


def receipt(phase="completion", reason="Original correction 汉字 100% \\ path."):
    return {"schema": "managed-completion-v2" if phase == "completion" else "managed-round-status-v2",
        "outcome": "target_not_met" if phase == "completion" else "unmeasurable", "decision": "repair",
        "reason_code": "target_not_met" if phase == "completion" else "owner_requested_repair",
        "reason": reason, "evidence_sha256": "a"*64}


def files(path):
    return {p.name: (p.read_bytes(), stat.S_IMODE(p.stat().st_mode)) for p in path.iterdir() if p.is_file()}


class RepairTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The production helper correctly rejects a bundle writable by a
        # different UID. Use a byte-identical private supervisor-owned copy
        # under both root and unprivileged test runners.
        global ROOT, HELPER
        cls.bundle=tempfile.TemporaryDirectory(prefix="native-repair-bundle-")
        source=ROOT;ROOT=Path(cls.bundle.name)/"humanize"
        shutil.copytree(source,ROOT,ignore=shutil.ignore_patterns(".git","__pycache__"))
        for path in [ROOT,*ROOT.rglob("*")]:
            if not path.is_symlink():path.chmod(stat.S_IMODE(path.stat().st_mode)&~0o022)
        HELPER=ROOT/"scripts/apply-managed-repair-v2.py"

    @classmethod
    def tearDownClass(cls):
        cls.bundle.cleanup()

    def fixture(self, active="state.md", current=2, maximum=4, mode=0o600):
        temporary = tempfile.TemporaryDirectory(prefix="native-repair-test-"); self.addCleanup(temporary.cleanup)
        root = Path(temporary.name); live = root/"loop"; live.mkdir(mode=0o700)
        for name, data in {active: f"---\ncurrent_round: {current}\nmax_iterations: {maximum}\nreview_started: true\nmainline_stall_count: 7\ndrift_status: offtrack\n---\nPreserve native body 汉字\n",
            ".review-phase-started": "original review marker\n", ".methodology-exit-reason": "COMPLETE\n",
            f"round-{current}-prompt.md": "Original current prompt\n", f"round-{current+1}-prompt.md": "Prior next prompt\n",
            f"round-{current}-benchmark.md": "Original benchmark receipt\n", f"round-{current}-benchmark.log": "Original exact capture\n",
            "round-0-prompt.md": "Historical prompt\n"}.items():
            (live/name).write_text(data); (live/name).chmod(0o600)
        (live/active).chmod(mode)
        return root, live

    def call(self, root, live, value=None, prepare=False, phase="completion", current=2, op=OP, env=None, plan_sha256=None, intent=None, plan_path=None):
        args = ["/usr/bin/python3.12", "-I", "-S", "-B", str(HELPER), "--loop-dir", str(live),
            "--phase", phase, "--expected-round", str(current), "--operation", op]
        plan_path=plan_path or root/"plan.json"
        args += ["--prepare"] if prepare else ["--plan", str(plan_path)]
        if not prepare:
            if intent is not None:args += ["--intent",str(intent)]
            else:args += ["--plan-sha256",plan_sha256 or hashlib.sha256(plan_path.read_bytes()).hexdigest()]
        return subprocess.run(args, input=json.dumps(value if value is not None else receipt(phase), ensure_ascii=False).encode(),
            cwd=root, env=env, capture_output=True, timeout=20)

    def plan(self, root, live, value=None, phase="completion", current=2):
        before = files(live)
        result = self.call(root, live, value, prepare=True, phase=phase, current=current)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(before, files(live), "prepare cannot change live lifecycle")
        (root/"plan.json").write_bytes(result.stdout); (root/"plan.json").chmod(0o600)
        return json.loads(result.stdout)

    def write_plan(self,root,plan):
        (root/"plan.json").write_bytes(json.dumps(plan,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()+b"\n")

    def legacy(self, root, live, value, active, current, maximum):
        legacy = root/"legacy"; shutil.copytree(live, legacy)
        callback = root/"original-callback"
        callback.write_text("#!/bin/sh\ncat <<'RECEIPT'\n" + json.dumps({"schema": "managed-completion-v1", "decision": "repair",
            "reason": value["reason"], "evidence_sha256": value["evidence_sha256"]}, ensure_ascii=False) + "\nRECEIPT\n")
        callback.chmod(0o700)
        script = '''set -euo pipefail
umask 077
source "$1/hooks/lib/loop-common.sh"
PLUGIN_ROOT="$1"
source "$1/hooks/lib/lifecycle-rules.sh"
lifecycle_rules_init
source "$1/hooks/lib/managed-completion.sh"
LOOP_DIR="$2"; STATE_FILE="$2/$3"; CURRENT_ROUND="$4"; MAX_ITERATIONS="$5"
export HUMANIZE_MANAGED_RELIABILITY_V1=1 HUMANIZE_COMPLETION_VALIDATOR="$6"
if managed_completion_validation; then exit 91; fi
'''
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", script, "test", str(ROOT), str(legacy), active,
            str(current), str(maximum), str(callback)], env={"PATH": "/usr/bin:/bin", "LC_ALL": "C.UTF-8"}, cwd=root, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        # Explicit v2 diagnostic difference: v2 original receipt/plan is in
        # Node's private stage; it does not create the v1 validation document.
        validation = legacy/f"round-{current}-completion-validation.json"
        self.assertTrue(validation.is_file()); validation.unlink()
        return result.stdout, files(legacy)

    def test_differential_native_states_budget_edges_reasons_stdout_and_modes(self):
        for active in ["state.md", "finalize-state.md", "methodology-analysis-state.md"]:
            for current, maximum in [(1, 3), (2, 3), (3, 3), (4, 3)]:
                for reason in ["Correction 汉字 100% \\ literal", "Trailing LF\n\n"]:
                    with self.subTest(active=active,current=current,maximum=maximum,reason=reason):
                        root, live = self.fixture(active, current, maximum); value = receipt(reason=reason)
                        stdout, expected = self.legacy(root, live, value, active, current, maximum)
                        self.plan(root, live, value, current=current)
                        first = self.call(root, live, value, current=current)
                        self.assertEqual(first.returncode, 0, first.stderr.decode())
                        self.assertEqual(first.stdout, stdout); self.assertEqual(files(live), expected)
                        before = files(live)
                        second = self.call(root, live, value, current=current)
                        self.assertEqual(second.returncode, 0, second.stderr.decode())
                        self.assertEqual(second.stdout, stdout); self.assertEqual(files(live), before)
                        self.assertEqual((live/".review-phase-started").exists(), current >= maximum)

    def test_round_owner_tuple_is_protocol_only_but_has_same_native_effects(self):
        root, live = self.fixture(); value=receipt("round")
        stdout, expected = self.legacy(root, live, value, "state.md", 2, 4)
        self.plan(root, live, value, phase="round")
        result = self.call(root, live, value, phase="round")
        self.assertEqual(result.returncode, 0, result.stderr.decode()); self.assertEqual(result.stdout, stdout)
        self.assertEqual(files(live), expected)

    def test_noncanonical_budget_missing_duplicate_and_control_reason_never_prepare(self):
        for field in ["current_round", "max_iterations"]:
            for value in ["08", "+1", "", "1 2", "9999999999999999999", "2\n"+field+": 2"]:
                root, live = self.fixture()
                path=live/"state.md"; original=path.read_text(); lines=original.splitlines()
                path.write_text("\n".join((field+": "+value) if line.startswith(field+":") else line for line in lines)+"\n")
                before=files(live); result=self.call(root,live,prepare=True)
                self.assertNotEqual(result.returncode,0); self.assertEqual(result.stdout,b""); self.assertEqual(files(live),before)
        root,live=self.fixture();path=live/"state.md";path.write_text(path.read_text().replace("max_iterations: 4\n",""));before=files(live)
        self.assertNotEqual(self.call(root,live,prepare=True).returncode,0);self.assertEqual(files(live),before)
        for reason in ["CRLF\r\n", "NUL\x00"]:
            root,live=self.fixture();before=files(live)
            self.assertNotEqual(self.call(root,live,receipt(reason=reason),prepare=True).returncode,0);self.assertEqual(files(live),before)

    def test_unapproved_dispositions_cannot_prepare_native_mutation(self):
        for decision in ["pass", "pause", "continue"]:
            root,live=self.fixture();value=receipt();value["decision"]=decision;before=files(live)
            self.assertNotEqual(self.call(root,live,value,prepare=True).returncode,0);self.assertEqual(files(live),before)

    def test_wrong_operation_round_phase_receipt_and_partial_before_never_apply(self):
        for what in ["operation", "round", "phase", "receipt", "partial", "same-length-state", "loop"]:
            root,live=self.fixture();self.plan(root,live);kwargs={};target=live
            if what=="operation":kwargs["op"]="01K9G000000000000000000001"
            if what=="round":kwargs["current"]=3
            if what=="phase":kwargs.update(phase="round",value=receipt("round"))
            if what=="receipt":kwargs["value"]=receipt(reason="Different original result")
            if what=="partial":(live/"round-3-prompt.md").write_text("partially applied\n")
            if what=="same-length-state":
                path=live/"state.md";path.write_text(path.read_text().replace("current_round: 2","current_round: 3"))
            if what=="loop":target=root/"other";shutil.copytree(live,target)
            before=files(target);result=self.call(root,target,**kwargs)
            self.assertNotEqual(result.returncode,0,what);self.assertEqual(result.stdout,b"");self.assertEqual(files(target),before)

    def test_duplicate_concurrent_apply_consumes_one_round(self):
        root,live=self.fixture();self.plan(root,live)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda _:self.call(root,live),range(8)))
        self.assertTrue(all(r.returncode==0 for r in results),[r.stderr for r in results])
        self.assertEqual(len({r.stdout for r in results}),1)
        self.assertIn("current_round: 3",(live/"state.md").read_text());self.assertFalse((live/"round-4-prompt.md").exists())

    def test_links_traversal_unknown_paths_and_bad_plan_are_rejected(self):
        for link in ["symlink", "hardlink"]:
            root,live=self.fixture();outside=root/"outside";outside.write_bytes((live/"state.md").read_bytes());outside.chmod(0o600)
            (live/"state.md").unlink()
            if link=="symlink":(live/"state.md").symlink_to(outside)
            else:os.link(outside,live/"state.md")
            self.assertNotEqual(self.call(root,live,prepare=True).returncode,0)
            self.assertIn(b"current_round: 2",outside.read_bytes())
        for name in ["../source.py", "solution/kernel.py", "round-0-prompt.md", "unknown.md"]:
            root,live=self.fixture();plan=self.plan(root,live);plan["effects"][0]["path"]=name
            self.write_plan(root,plan);before=files(live)
            self.assertNotEqual(self.call(root,live).returncode,0);self.assertEqual(files(live),before)
        root,live=self.fixture();self.plan(root,live);path=root/"plan.json";path.write_text(path.read_text().replace('"schema":','"schema":"duplicate","schema":',1));before=files(live)
        self.assertNotEqual(self.call(root,live).returncode,0);self.assertEqual(files(live),before)

    def test_task_environment_cannot_override_fixed_native_library_or_decoder(self):
        root,live=self.fixture();poison=root/"poison";poison.write_text("touch \""+str(root/"executed-poison")+"\"\n")
        (root/"json.py").write_text("raise RuntimeError('task import poison')\n")
        task_tmp=root/"task-tmp";task_tmp.mkdir(mode=0o777)
        env=dict(os.environ,BASH_ENV=str(poison),ENV=str(poison),PYTHONPATH=str(root),FIELD_CURRENT_ROUND="poison",PATH=str(root),TMPDIR=str(task_tmp))
        before=files(live);result=self.call(root,live,prepare=True,env=env)
        self.assertEqual(result.returncode,0,result.stderr.decode());self.assertEqual(files(live),before);self.assertFalse((root/"executed-poison").exists())
        self.assertEqual(list(task_tmp.iterdir()),[])

    def test_nontrivial_native_state_modes_match_continue_and_maxiter(self):
        for active in ["state.md","finalize-state.md","methodology-analysis-state.md"]:
            for maximum in [2,4]:
                root,live=self.fixture(active=active,maximum=maximum,mode=0o640)
                stdout,expected=self.legacy(root,live,receipt(),active,2,maximum)
                self.plan(root,live);result=self.call(root,live)
                self.assertEqual(result.returncode,0,result.stderr.decode());self.assertEqual(result.stdout,stdout);self.assertEqual(files(live),expected)
                target="maxiter-state.md" if maximum==2 else "state.md"
                self.assertEqual(stat.S_IMODE((live/target).stat().st_mode),0o640 if maximum==2 else 0o600)

    def test_protected_intent_hash_and_exact_canonical_plan_bytes_are_required(self):
        for variant in ["hash","noncanonical","utf16","intent","intent-positive"]:
            root,live=self.fixture();plan=self.plan(root,live);path=root/"plan.json";kwargs={}
            if variant=="hash":kwargs["plan_sha256"]="f"*64
            if variant=="noncanonical":path.write_text(json.dumps(plan,indent=2))
            if variant=="utf16":path.write_bytes(json.dumps(plan).encode("utf-16"))
            if variant.startswith("intent"):
                intent={"schema":"humanize-native-repair-intent-v2","state":"native_apply_pending","operation_id":OP,"phase":"completion","before_round":2,
                    "receipt_sha256":hashlib.sha256(json.dumps(receipt(),ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest(),
                    "plan_sha256":hashlib.sha256(path.read_bytes()).hexdigest() if variant=="intent-positive" else "f"*64}
                bound=root/"intent.json";bound.write_bytes(json.dumps(intent,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()+b"\n");bound.chmod(0o600);kwargs["intent"]=bound
            before=files(live);result=self.call(root,live,**kwargs)
            if variant=="intent-positive":self.assertEqual(result.returncode,0,result.stderr.decode())
            else:self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,b"");self.assertEqual(files(live),before)

    def test_internally_consistent_old_prompt_effect_is_rejected_by_path_allowlist(self):
        root,live=self.fixture();plan=self.plan(root,live)
        data=b"Forbidden historical prompt rewrite\n"
        import base64
        plan["effects"].append({"path":"round-0-prompt.md","after":{"data":base64.b64encode(data).decode(),"mode":0o600}})
        plan["expected_after"]["files"]["round-0-prompt.md"]={"bytes":len(data),"sha256":hashlib.sha256(data).hexdigest()}
        plan["after_modes"]["round-0-prompt.md"]=0o600
        self.write_plan(root,plan);before=files(live)
        module=self.module();fd=module.directory(live)
        args=SimpleNamespace(plan=root/"plan.json",intent=None,plan_sha256=hashlib.sha256((root/"plan.json").read_bytes()).hexdigest(),operation=OP,phase="completion",expected_round=2,loop_dir=live)
        try:
            with self.assertRaisesRegex(ValueError,"unexpected/duplicate path"):module.apply(fd,args,receipt())
        finally:os.close(fd)
        self.assertEqual(files(live),before)

    @staticmethod
    def module():
        spec=importlib.util.spec_from_file_location("native_effect_fixture",HELPER);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

    def test_every_effect_crash_retains_a_state_and_partial_reconciles(self):
        module=self.module()
        for active in ["state.md","finalize-state.md","methodology-analysis-state.md"]:
            for maximum in [2,4]:
                root,live=self.fixture(active=active,maximum=maximum);plan=self.plan(root,live);original=files(live)
                for point in range(1,len(plan["effects"])+1):
                    for p in live.iterdir():p.unlink()
                    for name,(data,mode) in original.items():(live/name).write_bytes(data);(live/name).chmod(mode)
                    args=SimpleNamespace(plan=root/"plan.json",intent=None,plan_sha256=hashlib.sha256((root/"plan.json").read_bytes()).hexdigest(),operation=OP,phase="completion",expected_round=2,loop_dir=live)
                    actual_replace=os.replace;actual_unlink=os.unlink;count=[0]
                    def reached(name):
                        if name in {effect["path"] for effect in plan["effects"]}:
                            count[0]+=1
                            if count[0]==point:raise OSError("injected process crash after native effect")
                    def replace(src,dst,**kw):actual_replace(src,dst,**kw);reached(dst)
                    def unlink(name,**kw):actual_unlink(name,**kw);reached(name)
                    fd=module.directory(live)
                    try:
                        with patch.object(module.os,"replace",side_effect=replace),patch.object(module.os,"unlink",side_effect=unlink):
                            with self.assertRaisesRegex(OSError,"injected process crash"):module.apply(fd,args,receipt())
                        self.assertTrue(any((live/name).exists() for name in [*module.ACTIVE,"maxiter-state.md"]),(active,maximum,point))
                        current=module.capture(fd,2);expected=(plan["expected_after"],plan["after_modes"])
                        self.assertEqual(current==expected,point==len(plan["effects"]),(active,maximum,point))
                        if current==expected:
                            before=files(live);module.apply(fd,args,receipt());self.assertEqual(files(live),before)
                        else:
                            with self.assertRaisesRegex(ValueError,"partial/conflicting"):module.apply(fd,args,receipt())
                    finally:os.close(fd)

    def test_mode_only_changes_and_unprotected_plan_locations_are_rejected(self):
        for variant in ["mode","symlink","inside-loop","writable-dir"]:
            root,live=self.fixture();self.plan(root,live);kwargs={}
            if variant=="mode":(live/"state.md").chmod(0o640)
            if variant=="symlink":
                actual=root/"actual-plan";(root/"plan.json").rename(actual);(root/"plan.json").symlink_to(actual)
            if variant=="inside-loop":
                target=live/"plan.json";(root/"plan.json").rename(target);kwargs["plan_path"]=target
            if variant=="writable-dir":root.chmod(0o770)
            before=files(live);result=self.call(root,live,**kwargs)
            self.assertNotEqual(result.returncode,0,variant);self.assertEqual(files(live),before)

    def test_each_intent_binding_and_protection_failure_blocks_before_native_writes(self):
        for variant in ["state","schema","operation_id","phase","before_round","boolean_round","receipt_sha256","extra","noncanonical","inside-loop","symlink","writable-dir"]:
            root,live=self.fixture();self.plan(root,live);intent={"schema":"humanize-native-repair-intent-v2","state":"native_apply_pending",
                "operation_id":OP,"phase":"completion","before_round":2,
                "receipt_sha256":hashlib.sha256(json.dumps(receipt(),ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest(),
                "plan_sha256":hashlib.sha256((root/"plan.json").read_bytes()).hexdigest()}
            changes={"state":"settled","schema":"v1","operation_id":"01K9G000000000000000000001","phase":"round","before_round":3,"receipt_sha256":"f"*64}
            if variant in changes:intent[variant]=changes[variant]
            if variant=="boolean_round":intent["before_round"]=True
            if variant=="extra":intent["unreviewed_field"]=True
            path=(live if variant=="inside-loop" else root)/"intent.json"
            path.write_bytes(json.dumps(intent,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()+b"\n");path.chmod(0o600)
            if variant=="noncanonical":path.write_text(json.dumps(intent,indent=2))
            if variant=="symlink":
                actual=root/"actual-intent";path.rename(actual);path.symlink_to(actual)
            if variant=="writable-dir":root.chmod(0o770)
            before=files(live);result=self.call(root,live,intent=path)
            self.assertNotEqual(result.returncode,0,variant);self.assertEqual(result.stdout,b"");self.assertEqual(files(live),before)

    def test_residual_temporary_files_do_not_change_full_ack_or_partial_reconcile(self):
        root,live=self.fixture();self.plan(root,live)
        leftover=live/(".native-repair-"+"a"*32);leftover.write_bytes(b"unfinished temporary write");leftover.chmod(0o600)
        self.assertEqual(self.call(root,live).returncode,0)
        before=files(live);self.assertEqual(self.call(root,live).returncode,0);self.assertEqual(files(live),before)
        self.assertEqual(leftover.read_bytes(),b"unfinished temporary write")
        root,live=self.fixture();plan=self.plan(root,live)
        leftover=live/(".native-repair-"+"b"*32);leftover.write_bytes(b"partial temp");leftover.chmod(0o600)
        (live/"round-3-prompt.md").write_bytes(b"partial formal effect")
        before=files(live);self.assertNotEqual(self.call(root,live).returncode,0);self.assertEqual(files(live),before)


if __name__=="__main__":unittest.main()
