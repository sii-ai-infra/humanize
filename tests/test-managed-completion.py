#!/usr/bin/env python3
"""Actual native lifecycle helper tests; the validator is an explicit CPU fixture."""
import json, os, pathlib, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class ManagedCompletion(unittest.TestCase):
    def run_case(self, decision='repair', lifecycle='finalize-state.md', current=2, limit=5, enabled=True, malformed=False):
        tmp=tempfile.TemporaryDirectory(prefix='humanize-managed-');self.addCleanup(tmp.cleanup)
        d=pathlib.Path(tmp.name);state=d/lifecycle
        state.write_text(f'---\ncurrent_round: {current}\nmax_iterations: {limit}\nreview_started: true\n---\n')
        (d/f'round-{current}-summary.md').write_text('original immutable prior summary\n')
        (d/'.review-phase-started').write_text('original review\n')
        if lifecycle.startswith('methodology'): (d/'.methodology-exit-reason').write_text('complete\n')
        v=d/'validator';out='not-json' if malformed else json.dumps({'schema':'managed-completion-v1','decision':decision,'reason':'actual evidence requires correction','evidence_sha256':'a'*64})
        v.write_text('#!/usr/bin/env python3\nprint('+repr(out)+')\n');v.chmod(0o700)
        script='''set -euo pipefail
source "$1/hooks/lib/loop-common.sh"
source "$1/hooks/lib/managed-completion.sh"
LOOP_DIR="$2"; STATE_FILE="$2/$3"; CURRENT_ROUND="$4"; MAX_ITERATIONS="$5"
export HUMANIZE_MANAGED_RELIABILITY_V1="$6" HUMANIZE_COMPLETION_VALIDATOR="$2/validator"
if managed_completion_validation; then printf 'validated\\n' >&2; else printf 'blocked\\n' >&2; fi
'''
        p=subprocess.run(['bash','-c',script,'test',str(ROOT),str(d),lifecycle,str(current),str(limit),'1' if enabled else ''],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr);self.assertEqual((d/f'round-{current}-summary.md').read_text(),'original immutable prior summary\n')
        return d,p
    def test_finalize_negative_returns_same_native_loop_next_round(self):
        d,p=self.run_case();self.assertIn('current_round: 3',(d/'state.md').read_text());self.assertFalse((d/'finalize-state.md').exists());self.assertFalse((d/'.review-phase-started').exists());self.assertEqual(json.loads(p.stdout)['repair_round'],3)
    def test_methodology_negative_does_not_leave_stale_complete_reason(self):
        d,p=self.run_case(lifecycle='methodology-analysis-state.md');self.assertTrue((d/'state.md').exists());self.assertFalse((d/'.methodology-exit-reason').exists());self.assertFalse((d/'complete-state.md').exists())
    def test_last_budget_cannot_be_reset_or_become_success(self):
        d,p=self.run_case(current=5,limit=5);self.assertTrue((d/'maxiter-state.md').exists());self.assertFalse((d/'state.md').exists());self.assertFalse((d/'complete-state.md').exists())
    def test_platform_block_keeps_same_lifecycle_and_budget(self):
        d,p=self.run_case(decision='platform_blocked');self.assertIn('current_round: 2',(d/'finalize-state.md').read_text());self.assertTrue(json.loads(p.stdout)['platform_blocked']);self.assertFalse((d/'state.md').exists())
    def test_invalid_result_cannot_finish(self):
        d,p=self.run_case(malformed=True);self.assertTrue((d/'finalize-state.md').exists());self.assertTrue(json.loads(p.stdout)['platform_blocked'])
    def test_real_positive_is_only_permission_for_native_caller(self):
        d,p=self.run_case(decision='pass');self.assertIn('validated',p.stderr);self.assertTrue((d/'finalize-state.md').exists());self.assertFalse((d/'complete-state.md').exists())
    def test_old_unmanaged_native_path_is_unchanged(self):
        d,p=self.run_case(enabled=False);self.assertIn('validated',p.stderr);self.assertFalse((d/'round-2-completion-validation.json').exists())
if __name__=='__main__': unittest.main()
