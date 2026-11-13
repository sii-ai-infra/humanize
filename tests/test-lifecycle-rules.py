"""Bounded DATA and real 590/new native-script differential components.

No real model or performance benchmark is run. Codex/validator and the
mandatory benchmark command are explicit fixed-output CPU fixtures.
The old script bodies come from the pinned local Git object, never from the new
matcher. These tests do not establish Node execution/approval or business E2E.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = "5902799f901f3e8720ed78cc821d6e30a85dc643"
TABLE = "references/lifecycle-rules-v1.json"
TABLE_SHA = "fa774628d4b648e52645e231e72996c6e23e49c4e32104e2afea0f7238ee070c"
CHANGED = ("hooks/loop-codex-stop-hook.sh", "hooks/lib/methodology-analysis.sh",
           "hooks/lib/managed-completion.sh", "scripts/prepare-managed-repair-v2.sh")
CASES = {
    "budget_precheck": ("implementation_within", "implementation_beyond", "review_within", "review_beyond", "finalize_within", "finalize_beyond"),
    "implementation_complete": ("at_or_above", "below_with_base", "below_without_base"),
    "enter_finalize": ("review_passed",), "review_issues": ("issues_present",),
    "implementation_issues": ("continue",),
    "methodology_enter": ("privacy", "already_active", "nonempty_done", "enter"),
    "methodology_finish": ("complete", "stop", "maxiter"),
    "completion_repair": ("within", "beyond"),
    "node_outcome": ("complete_exit0", "maxiter_exit0", "state_exit0", "state_exit10", "finalize_exit0", "finalize_exit10", "methodology_exit0", "methodology_exit10", "other"),
    "node_round": ("same", "next", "outside"),
}
RESULTS = {
    "budget_precheck": {"proceed", "request_maxiter"},
    "implementation_complete": {"request_maxiter", "enter_review", "skip_review"},
    "enter_finalize": {"finalize_same_round"}, "review_issues": {"review_next_round"},
    "implementation_issues": {"implementation_next_round"},
    "methodology_enter": {"skip_privacy", "skip_already_active", "skip_nonempty_done", "enter_methodology_same_round"},
    "methodology_finish": {"complete_same_round", "stop_same_round", "maxiter_same_round"},
    "completion_repair": {"repair_next_round", "maxiter_same_round"},
    "node_outcome": {"complete", "limit_reached", "continue", "error"},
    "node_round": {"accept", "reject"},
}

def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate JSON field")
        obj[key] = value
    return obj


def strict_table(raw):
    if not 0 < len(raw) <= 16384:
        raise ValueError("byte bound")
    table = json.loads(raw, object_pairs_hook=unique_object)
    if set(table) != {"schema", "node_observe", "records"} or table["schema"] != "humanize-lifecycle-rules-v1":
        raise ValueError("root schema")
    observe = table["node_observe"]
    if not isinstance(observe, dict) or set(observe) != {"mode", "enabled_rule_ids"} or observe["mode"] not in ("shadow", "enforce"):
        raise ValueError("observe schema")
    records = table["records"]
    if not isinstance(records, list) or len(records) > 64:
        raise ValueError("record bound/array")
    pairs, ids = set(), set()
    for row in records:
        if not isinstance(row, dict) or set(row) != {"site", "case", "rule_id", "result"}:
            raise ValueError("row schema")
        pair = row["site"], row["case"]
        if (pair in pairs or row["rule_id"] in ids or row["site"] not in CASES
                or row["case"] not in CASES[row["site"]]
                or row["rule_id"] != ".".join(pair) or row["result"] not in RESULTS[row["site"]]):
            raise ValueError("crossed/duplicate/unknown row")
        pairs.add(pair); ids.add(row["rule_id"])
    if pairs != {(site, case) for site, cases in CASES.items() for case in cases}:
        raise ValueError("incomplete cases")
    enabled = observe["enabled_rule_ids"]
    if not isinstance(enabled, list) or len(enabled) > 64 or len(set(enabled)) != len(enabled) or any(
            not isinstance(v, str) or v not in ids or not v.startswith(("node_outcome.", "node_round.")) for v in enabled):
        raise ValueError("enabled set")
    return table


def call(args, *, cwd=None, env=None, data=None):
    return subprocess.run(args, cwd=cwd, env=env, input=data, capture_output=True, timeout=40)


def files(root):
    return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mode & 0o777)
            for p in sorted(root.rglob("*")) if p.is_file()}


class Rules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="humanize-rules-diff-")
        cls.work = Path(cls.temp.name)
        cls.old = cls.work / "humanize-590"
        shutil.copytree(ROOT, cls.old, ignore=shutil.ignore_patterns(".git", "__pycache__"))
        for relative in CHANGED:
            original = call(["git", "-C", str(ROOT), "show", f"{BASE}:{relative}"])
            if original.returncode:
                raise RuntimeError("pinned original 590 Git object is required: " + original.stderr.decode())
            (cls.old / relative).write_bytes(original.stdout)
        (cls.old / TABLE).unlink()
        (cls.old / "hooks/lib/lifecycle-rules.sh").unlink()
        cls.fixture_bin = cls.work / "bin"; cls.fixture_bin.mkdir()
        codex = cls.fixture_bin / "codex"
        codex.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
case " $* " in
  *" review "*) printf '%s\\n' "$FIXTURE_REVIEW" ;;
  *" exec "*) cat >/dev/null; printf '%s\\n' "$FIXTURE_IMPLEMENTATION" > "$FIXTURE_RESULT_FILE"; printf '%s\\n' "$FIXTURE_IMPLEMENTATION" ;;
  *" --version "*) printf '%s\\n' 'codex fixture-590-differential' ;;
  *) printf '%s\\n' 'fixture feature discovery' ;;
esac
''')
        codex.chmod(0o700)
        # Only original presentation timestamps are deterministic fixtures;
        # timeout/process supervision remains the real original implementation.
        date = cls.fixture_bin / "date"
        date.write_text('#!/bin/sh\nexec /bin/date --date=2026-11-13T00:00:00Z "$@"\n')
        date.chmod(0o700)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def temporary(self):
        value = tempfile.TemporaryDirectory(prefix="humanize-rules-case-"); self.addCleanup(value.cleanup)
        return Path(value.name)

    def test_fixed_table_strict_and_golden_queries(self):
        raw = (ROOT / TABLE).read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), TABLE_SHA)
        strict_table(raw)
        # Source-derived expectations are independent literals, not matcher output.
        expected = [("budget_precheck", "review_beyond", "proceed"),
                    ("budget_precheck", "implementation_beyond", "request_maxiter"),
                    ("implementation_complete", "at_or_above", "request_maxiter"),
                    ("enter_finalize", "review_passed", "finalize_same_round"),
                    ("review_issues", "issues_present", "review_next_round"),
                    ("completion_repair", "beyond", "maxiter_same_round")]
        for site, case, result in expected:
            script = 'set -euo pipefail; PLUGIN_ROOT="$1"; source "$1/hooks/lib/lifecycle-rules.sh"; lifecycle_rules_init; lifecycle_rule "$2" "$3"; printf "%s\\n" "$LIFECYCLE_RESULT"'
            proc = call(["bash", "--noprofile", "--norc", "-c", script, "fixture", str(ROOT), site, case])
            self.assertEqual((proc.returncode, proc.stdout), (0, (result+"\n").encode()), proc.stderr)

    def test_strict_decoder_rejects_duplicates_and_unknowns(self):
        raw = (ROOT / TABLE).read_bytes()
        duplicate = raw.replace(b'"schema":', b'"schema":"humanize-lifecycle-rules-v1","schema":', 1)
        for value in (duplicate, b" "*16385):
            with self.assertRaises(ValueError): strict_table(value)
        for variant in range(6):
            value = json.loads(raw)
            if variant == 0: value["records"][1] = value["records"][0]
            if variant == 1: value["records"][0]["case"] = "unknown"
            if variant == 2: value["records"].pop()
            if variant == 3: value["extra"] = None
            if variant == 4: value["node_observe"]["enabled_rule_ids"] = ["completion_repair.within"]
            if variant == 5: value["records"][0]["result"] = "new_permission"
            with self.assertRaises(ValueError): strict_table(json.dumps(value).encode())

    def hook_fixture(self, path, *, lifecycle="state.md", current=2, maximum=5,
                     review=False, privacy=True, base="main", methodology=None):
        path.mkdir(); git = ["git", "-C", str(path)]
        self.assertEqual(call(git+["init", "-q", "-b", "main"]).returncode, 0)
        (path/".gitignore").write_text(".humanize/\n.cache/\n")
        (path/"plan.md").write_text("# Original fixture plan\n\nKeep the original numerical definition.\n")
        (path/"kernel.py").write_text("# Static dirty-tree fixture; never executed.\n")
        self.assertEqual(call(git+["add", "."]).returncode, 0)
        self.assertEqual(call(git+["-c", "user.email=fixture@invalid", "-c", "user.name=Fixture", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]).returncode, 0)
        commit = call(git+["rev-parse", "HEAD"]).stdout.decode().strip()
        loop = path/".humanize/rlcr/2026-11-13_00-00-00"; loop.mkdir(parents=True)
        fields = {"current_round":current,"max_iterations":maximum,"codex_model":"fixture-model",
                  "codex_effort":"high","codex_timeout":10,"push_every_round":"false","full_review_round":5,
                  "plan_file":"plan.md","plan_tracked":"false","start_branch":"main","base_branch":base,
                  "base_commit":commit,"review_started":str(review).lower(),"ask_codex_question":"false",
                  "session_id":"","agent_teams":"false","privacy_mode":str(privacy).lower()}
        (loop/lifecycle).write_text("---\n"+"".join(f"{k}: {v}\n" for k,v in fields.items())+"---\nOriginal native body\n")
        (loop/"plan.md").write_bytes((path/"plan.md").read_bytes())
        (loop/f"round-{current}-summary.md").write_text("Completed the bounded fixture change.\n")
        (loop/"finalize-summary.md").write_text("Completed the fixed review cleanup.\n")
        # Reach the original mandatory benchmark guard with an explicit CPU
        # callback. The original runner writes its real result/log receipt;
        # this is synthetic transition evidence, not a performance result.
        (loop/"benchmark-command.sh").write_text("printf '%s\\n' 'synthetic CPU fixture, not performance evidence'; printf '%s\\n' benchmark >> .humanize/fixture-benchmark-calls\n")
        (loop/"benchmark-timeout").write_text("10\n")
        if review: (loop/".review-phase-started").write_text(f"build_finish_round={current}\n")
        if methodology:
            (loop/"methodology-analysis-done.md").write_text("Done\n")
            (loop/"methodology-analysis-report.md").write_text("Original report\n")
            (loop/".methodology-exit-reason").write_text(methodology+"\n")
        return loop

    def run_hook(self, bundle, project, implementation, review):
        loop=project/".humanize/rlcr/2026-11-13_00-00-00"
        active=next(loop/name for name in ("state.md","finalize-state.md","methodology-analysis-state.md") if (loop/name).exists())
        current=next(line.split(":",1)[1].strip() for line in active.read_text().splitlines() if line.startswith("current_round:"))
        env = {"PATH":str(self.fixture_bin)+":/usr/bin:/bin", "LC_ALL":"C.UTF-8",
               "CLAUDE_PROJECT_DIR":str(project),"XDG_CACHE_HOME":str(project/".cache"),
               "FIXTURE_CALLS":str(project/".humanize/fixture-codex-calls"),
               "FIXTURE_IMPLEMENTATION":implementation,"FIXTURE_REVIEW":review,
               "FIXTURE_RESULT_FILE":str(loop/f"round-{current}-review-result.md")}
        return call(["bash", str(bundle/"hooks/loop-codex-stop-hook.sh")], cwd=project, env=env, data=b'{}')

    def comparable(self, value, root, bundle):
        # Only exact private absolute roots and the original cache's literal
        # sanitized-root derivative differ. No time/hash/semantic field is cut.
        sanitized=re.sub(r"-+","-",re.sub(r"[^a-zA-Z0-9._-]","-",str(root)))
        return value.replace(str(root).encode(),b"<PROJECT>").replace(str(bundle).encode(),b"<BUNDLE>").replace(sanitized.encode(),b"<PROJECT-CACHE-KEY>")

    def test_real_hook_original_590_and_new_differential(self):
        # Last tuple: exact exec/review/synthetic-benchmark invocations. This
        # prevents two equally early blocked runs being treated as equivalence.
        cases = [
            ({"current":5,"maximum":5}, "maxiter-state.md", 5, "fixes", "No issues", (0,0,0)),
            ({"lifecycle":"finalize-state.md","current":5,"maximum":5,"review":True}, "complete-state.md", 5, "fixes", "No issues", (0,0,0)),
            ({"review":True,"current":5,"maximum":5}, "finalize-state.md", 5, "fixes", "No review issues", (0,1,1)),
            ({"review":True,"current":2}, "state.md", 3, "fixes", "[P1] Correct the fixture issue", (0,1,1)),
            ({"current":2}, "finalize-state.md", 2, "Mainline Progress Verdict: ADVANCED\nCOMPLETE", "No review issues", (1,1,1)),
            ({"current":2}, "state.md", 3, "Mainline Progress Verdict: ADVANCED\nOriginal review requires fixes", "No issues", (1,0,1)),
            ({"lifecycle":"finalize-state.md","privacy":False}, "methodology-analysis-state.md", 2, "fixes", "No issues", (0,0,0)),
            ({"lifecycle":"methodology-analysis-state.md","methodology":"complete"}, "complete-state.md", 2, "fixes", "No issues", (0,0,0)),
            ({"lifecycle":"methodology-analysis-state.md","methodology":"stop"}, "stop-state.md", 2, "fixes", "No issues", (0,0,0)),
            ({"lifecycle":"methodology-analysis-state.md","methodology":"maxiter"}, "maxiter-state.md", 2, "fixes", "No issues", (0,0,0)),
            # The existing earlier schema guard blocks absent base_branch. Do
            # not bypass it just to make the later skip-review row reachable.
            ({"base":""}, "state.md", 2, "Mainline Progress Verdict: ADVANCED\nCOMPLETE", "No issues", (0,0,0)),
        ]
        for fields, target, round_after, implementation, review, expected_calls in cases:
            with self.subTest(fields=fields):
                d=self.temporary(); source=d/"seed"; self.hook_fixture(source, **fields)
                old=d/"old"; new=d/"new"; shutil.copytree(source,old);shutil.copytree(source,new)
                results=[]; trees=[]
                for bundle, project in ((self.old,old),(ROOT,new)):
                    proc=self.run_hook(bundle,project,implementation,review)
                    results.append((proc.returncode,self.comparable(proc.stdout,project,bundle),self.comparable(proc.stderr,project,bundle)))
                    loop=project/".humanize/rlcr/2026-11-13_00-00-00"
                    diagnostic=f"bundle={bundle}\nstdout={proc.stdout.decode(errors='replace')}\nstderr={proc.stderr.decode(errors='replace')}"
                    self.assertEqual(proc.returncode,0,diagnostic)
                    self.assertTrue((loop/target).is_file(),diagnostic)
                    self.assertIn(f"current_round: {round_after}\n".encode(),(loop/target).read_bytes(),diagnostic)
                    calls_path=project/".humanize/fixture-codex-calls"
                    calls=calls_path.read_text().splitlines() if calls_path.exists() else []
                    benchmark_path=project/".humanize/fixture-benchmark-calls"
                    benchmarks=benchmark_path.read_text().splitlines() if benchmark_path.exists() else []
                    observed=(sum("exec" in line.split() for line in calls),sum("review" in line.split() for line in calls),len(benchmarks))
                    self.assertEqual(observed,expected_calls,diagnostic)
                    if expected_calls[2]:
                        self.assertEqual(benchmarks,["benchmark"])
                        evidence=(loop/f"round-{fields.get('current',2)}-benchmark.md").read_text()
                        self.assertIn("- Status: **passed**",evidence)
                        self.assertIn("synthetic CPU fixture, not performance evidence",(loop/f"round-{fields.get('current',2)}-benchmark.log").read_text())
                    trees.append({name:(self.comparable(raw,project,bundle),mode) for name,(raw,mode) in files(loop).items()})
                self.assertEqual(results[0],results[1]); self.assertEqual(trees[0],trees[1])
                calls=lambda p:(p/".humanize/fixture-codex-calls").read_text() if (p/".humanize/fixture-codex-calls").exists() else ""
                self.assertEqual(self.comparable(calls(old).encode(),old,self.old),
                                 self.comparable(calls(new).encode(),new,ROOT),
                                 "no additional model/benchmark invocation")

    def test_real_methodology_entry_priority_original_590_differential(self):
        # These expected return values and messages come from the 590 library,
        # including its intentional non-trimming nonempty-done entry check.
        cases=[(True,True,"done",17,"privacy mode enabled"),
               (False,True,"done",17,"already active"),
               (False,False,"done",17,"already completed"),
               (False,False,"  ",17,"already completed"),
               (False,False,"",0,"State file renamed")]
        for privacy,active,done,expected_exit,message in cases:
            with self.subTest(privacy=privacy,active=active,done=repr(done)):
                d=self.temporary();results=[];trees=[]
                for label,bundle in (("old",self.old),("new",ROOT)):
                    loop=d/label;loop.mkdir()
                    (loop/"finalize-state.md").write_text("---\ncurrent_round: 2\nmax_iterations: 5\n---\nOriginal body\n")
                    if active:(loop/"methodology-analysis-state.md").write_text("Existing active phase\n")
                    (loop/"methodology-analysis-done.md").write_text(done)
                    before=files(loop)
                    init='source "$1/hooks/lib/lifecycle-rules.sh"; lifecycle_rules_init;' if label=="new" else ''
                    script='set -euo pipefail; PLUGIN_ROOT="$1";source "$1/hooks/lib/loop-common.sh"; '+init+' source "$1/hooks/lib/methodology-analysis.sh";LOOP_DIR="$2";STATE_FILE="$2/finalize-state.md";CURRENT_ROUND=2;MAX_ITERATIONS=5;PRIVACY_MODE="$3";if enter_methodology_analysis_phase complete "Original completion";then exit 0;else exit 17;fi'
                    proc=call(["bash","--noprofile","--norc","-c",script,"fixture",str(bundle),str(loop),str(privacy).lower()])
                    diagnostic=proc.stdout.decode(errors="replace")+proc.stderr.decode(errors="replace")
                    self.assertEqual(proc.returncode,expected_exit,diagnostic)
                    self.assertIn(message,proc.stderr.decode())
                    if expected_exit==17:
                        self.assertEqual(files(loop),before)
                        self.assertEqual(proc.stdout,b"")
                    else:
                        self.assertFalse((loop/"finalize-state.md").exists())
                        self.assertEqual((loop/"methodology-analysis-state.md").read_bytes(),before["finalize-state.md"][0])
                        self.assertEqual((loop/".methodology-exit-reason").read_text(),"complete\n")
                        self.assertEqual(json.loads(proc.stdout)["decision"],"block")
                    results.append((proc.returncode,self.comparable(proc.stdout,loop,bundle),self.comparable(proc.stderr,loop,bundle)))
                    trees.append({name:(self.comparable(raw,loop,bundle),mode) for name,(raw,mode) in files(loop).items()})
                self.assertEqual(results[0],results[1]);self.assertEqual(trees[0],trees[1])

    def test_real_methodology_completion_rejects_dirty_or_missing_report_without_transition(self):
        for issue in ("dirty","missing-report","empty-report","empty-done","missing-exit","invalid-exit"):
            with self.subTest(issue=issue):
                d=self.temporary();seed=d/"seed"
                loop=self.hook_fixture(seed,lifecycle="methodology-analysis-state.md",review=True,privacy=False,methodology="complete")
                if issue=="dirty":(seed/"kernel.py").write_text("# Uncommitted static fixture edit.\n")
                elif issue=="missing-report":(loop/"methodology-analysis-report.md").unlink()
                elif issue=="empty-report":(loop/"methodology-analysis-report.md").write_text("  \n")
                elif issue=="empty-done":(loop/"methodology-analysis-done.md").write_text("  \n")
                elif issue=="missing-exit":(loop/".methodology-exit-reason").unlink()
                else:(loop/".methodology-exit-reason").write_text("not-a-native-terminal\n")
                results=[];trees=[]
                for label,bundle in (("old",self.old),("new",ROOT)):
                    project=d/label;shutil.copytree(seed,project)
                    loop=project/".humanize/rlcr/2026-11-13_00-00-00";before=files(loop)
                    proc=self.run_hook(bundle,project,"must not run","must not run")
                    diagnostic=proc.stdout.decode(errors="replace")+proc.stderr.decode(errors="replace")
                    self.assertEqual(proc.returncode,0,diagnostic)
                    value=json.loads(proc.stdout);self.assertEqual(value["decision"],"block")
                    if issue=="dirty":self.assertIn("uncommitted changes detected after methodology",value["systemMessage"])
                    else:self.assertIn("Methodology Analysis Incomplete",value["reason"])
                    self.assertEqual(files(loop),before)
                    self.assertFalse((project/".humanize/fixture-codex-calls").exists())
                    self.assertFalse((project/".humanize/fixture-benchmark-calls").exists())
                    results.append((proc.returncode,self.comparable(proc.stdout,project,bundle),self.comparable(proc.stderr,project,bundle)))
                    trees.append(files(loop))
                self.assertEqual(results[0],results[1]);self.assertEqual(trees[0],trees[1])

    def test_real_private_prepare_and_live_repair_original_590_differential(self):
        for current,maximum in ((2,5),(5,5),(999999999999999998,999999999999999999),(999999999999999999,999999999999999999)):
            for private in (False,True):
                with self.subTest(current=current,private=private):
                    d=self.temporary(); results=[]; trees=[]
                    for label,bundle in (("old",self.old),("new",ROOT)):
                        loop=d/label;loop.mkdir()
                        (loop/"finalize-state.md").write_text(f"---\ncurrent_round: {current}\nmax_iterations: {maximum}\nreview_started: true\n---\n")
                        (loop/".review-phase-started").write_text("original\n")
                        receipt={"schema":"managed-completion-v1","decision":"repair","reason":"Original correction 汉字","evidence_sha256":"a"*64}
                        receipt_path=d/(label+"-receipt.json");receipt_path.write_text(json.dumps(receipt))
                        if private:
                            args=["bash",str(bundle/"scripts/prepare-managed-repair-v2.sh"),str(loop),"finalize-state.md",str(current),str(receipt_path)]
                        else:
                            callback=d/(label+"-validator");callback.write_text("#!/bin/sh\ncat '"+str(receipt_path)+"'\n");callback.chmod(0o700)
                            init='source "$1/hooks/lib/lifecycle-rules.sh"; lifecycle_rules_init;' if label=="new" else ''
                            script='set -euo pipefail; PLUGIN_ROOT="$1"; source "$1/hooks/lib/loop-common.sh"; '+init+' source "$1/hooks/lib/managed-completion.sh"; LOOP_DIR="$2";STATE_FILE="$2/finalize-state.md";CURRENT_ROUND="$3";MAX_ITERATIONS="$4";export HUMANIZE_MANAGED_RELIABILITY_V1=1 HUMANIZE_COMPLETION_VALIDATOR="$5"; if managed_completion_validation;then exit 91;fi'
                            args=["bash","-c",script,"fixture",str(bundle),str(loop),str(current),str(maximum),str(callback)]
                        proc=call(args); self.assertEqual(proc.returncode,0,proc.stderr)
                        results.append((proc.returncode,proc.stdout,proc.stderr));trees.append(files(loop))
                    self.assertEqual(results[0],results[1]);self.assertEqual(trees[0],trees[1])

    def test_helper_failure_blocks_real_hook_before_state_mutation(self):
        for corruption in ("missing", "bad-sha", "oversize", "duplicate"):
            d=self.temporary(); bundle=d/"bundle";shutil.copytree(ROOT,bundle,ignore=shutil.ignore_patterns(".git","__pycache__"))
            resource=bundle/TABLE; raw=resource.read_bytes()
            if corruption=="missing":resource.unlink()
            elif corruption=="oversize":resource.write_bytes(b" "*16385)
            elif corruption=="duplicate":resource.write_bytes(raw.replace(b'"schema":',b'"schema":"duplicate","schema":',1))
            else:resource.write_bytes(raw+b" ")
            project=d/"project";loop=self.hook_fixture(project);before=files(loop)
            proc=self.run_hook(bundle,project,"must not run","must not run")
            self.assertEqual(proc.returncode,0,proc.stderr); value=json.loads(proc.stdout)
            self.assertEqual(value["decision"],"block");self.assertTrue(value["platform_blocked"])
            self.assertEqual(files(loop),before);self.assertFalse((project/".humanize/fixture-codex-calls").exists())
            receipt=d/"receipt";receipt.write_text('{"reason":"unused"}')
            proc=call(["bash",str(bundle/"scripts/prepare-managed-repair-v2.sh"),str(loop),"state.md","2",str(receipt)])
            self.assertEqual(proc.returncode,2);self.assertEqual(files(loop),before)


    def test_failed_jq_or_crossed_result_is_rejected_during_preload(self):
        for failure in ("jq-failure", "crossed-result", "unknown-case", "sha-failure"):
            with self.subTest(failure=failure):
                d=self.temporary(); state=d/"state.md";state.write_text("unchanged native state\n")
                table=json.loads((ROOT/TABLE).read_bytes())
                rows=[":".join((r["site"],r["case"],r["result"])) for r in table["records"]]
                if failure=="crossed-result":rows[0]="budget_precheck:implementation_within:complete"
                if failure=="unknown-case":rows[0]="budget_precheck:unknown:proceed"
                supplied=d/"jq-output";supplied.write_text("\n".join(rows)+"\n")
                if failure=="jq-failure": override='jq() { return 7; };'
                elif failure=="sha-failure": override='sha256sum() { return 8; };'
                else: override='jq() { cat "$2"; };'  # replaced below with fixed fixture file
                if failure in ("crossed-result","unknown-case"):
                    override='jq() { cat "$FIXTURE_JQ_OUTPUT"; };'
                script='set -euo pipefail; PLUGIN_ROOT="$1";FIXTURE_JQ_OUTPUT="$2";source "$1/hooks/lib/lifecycle-rules.sh"; '+override+' if lifecycle_rules_init; then exit 91;else lifecycle_rules_block;fi'
                proc=call(["bash","-c",script,"fixture",str(ROOT),str(supplied)])
                self.assertEqual(proc.returncode,0,proc.stderr)
                self.assertTrue(json.loads(proc.stdout)["platform_blocked"])
                self.assertEqual(state.read_text(),"unchanged native state\n")


if __name__ == "__main__":
    unittest.main()
