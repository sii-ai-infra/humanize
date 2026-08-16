#!/usr/bin/env bash
# Deterministic W4b reducer/action-id/convergence-consumer tests.

set -uo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/lib/rlcr-reducer.sh"
source "$PLUGIN_ROOT/hooks/lib/rlcr-control.sh"
source "$PLUGIN_ROOT/hooks/lib/loop-state-write.sh"

PASSED=0
FAILED=0
pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '\033[0;31mFAIL\033[0m: %s\n  %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); }

expect_transition() {
    local label="$1" expected_phase="$2" expected_action="$3"
    shift 3
    reduce "$@" >/dev/null
    if [[ "$RLCR_REDUCER_NEXT_PHASE" == "$expected_phase" \
       && "$RLCR_REDUCER_ACTION" == "$expected_action" ]]; then
        pass "$label"
    else
        fail "$label" "got $RLCR_REDUCER_NEXT_PHASE/$RLCR_REDUCER_ACTION ($RLCR_REDUCER_REASON)"
    fi
}

echo "=== W4b RLCR reducer tests ==="

# Every public action is reached by a legal, reproducible tuple.
expect_transition "action continue_optimize" implementation continue_optimize \
    implementation none below_target remaining ok false
expect_transition "action continue_pivot" implementation continue_pivot \
    implementation STALLED group_stalled remaining ok false
expect_transition "action continue_closeout" implementation continue_closeout \
    implementation none pass closeout_only ok false
expect_transition "action enter_review" review enter_review \
    implementation COMPLETE pass remaining ok false
expect_transition "action terminal_success" terminal terminal_success \
    finalize COMPLETE pass closeout_only ok false
expect_transition "action terminal_exhausted" terminal terminal_exhausted \
    methodology-analysis STOP exhausted remaining ok false
expect_transition "action terminal_budget" methodology-analysis terminal_budget \
    implementation none below_target exhausted ok false
expect_transition "action terminal_blocked" terminal terminal_blocked \
    implementation COMPLETE pass exhausted tcb_tampered true
expect_transition "action terminal_cancelled" terminal terminal_cancelled \
    review none pass remaining ok true

# The two COMPLETE semantics and the review/finalize boundary are explicit.
expect_transition "COMPLETE below target cannot succeed" implementation continue_optimize \
    implementation COMPLETE below_target remaining ok false
expect_transition "COMPLETE plus pass enters review first" review enter_review \
    implementation COMPLETE pass remaining ok false
expect_transition "review pass enters finalize before success" finalize continue_closeout \
    review none pass closeout_only ok false

# Priority is blocked > cancelled > budget > closeout/convergence.
expect_transition "blocked outranks cancel budget and pass" terminal terminal_blocked \
    implementation COMPLETE pass exhausted tunnel_down true
expect_transition "cancel outranks budget and pass" terminal terminal_cancelled \
    implementation COMPLETE pass exhausted ok true
expect_transition "budget outranks nonpassing convergence" methodology-analysis terminal_budget \
    implementation ADVANCED below_target exhausted ok false
expect_transition "closeout_only preserves final passing round" review enter_review \
    implementation COMPLETE pass closeout_only ok false
expect_transition "missing convergence is blocked" terminal terminal_blocked \
    implementation none missing remaining ok false
expect_transition "stale convergence is blocked" terminal terminal_blocked \
    finalize COMPLETE stale closeout_only ok false
expect_transition "invalid tuple fails closed" terminal terminal_blocked \
    impossible none pass remaining ok false
expect_transition "phase-unreachable reviewer signal fails closed" terminal terminal_blocked \
    review ADVANCED pass remaining ok false

# Persisted closeout budget is bounded but permits terminal finalize at the
# exact bound.
if [[ "$(rlcr_reduce_budget implementation pass 5 5 0 2)" == closeout_only \
   && "$(rlcr_reduce_budget review pass 5 5 1 2)" == closeout_only \
   && "$(rlcr_reduce_budget implementation pass 5 5 2 2)" == exhausted \
   && "$(rlcr_reduce_budget finalize pass 5 5 2 2)" == closeout_only ]]; then
    pass "bounded closeout_only budget"
else
    fail "bounded closeout_only budget"
fi

# Complete Cartesian-domain traversal: all five phases and all declared signal
# values produce one of the nine actions; no implicit/default continue exists.
phases=(implementation review finalize methodology-analysis terminal)
signals=(COMPLETE STOP mainline_drift review_issue:P1 ADVANCED STALLED REGRESSED none)
convergences=(pass below_target group_stalled exhausted stale missing evaluator_error)
budgets=(remaining exhausted closeout_only)
infras=(ok device_unavailable tunnel_down tcb_tampered)
cancels=(false true)
matrix_ok=true
RLCR_REDUCER_NO_OUTPUT=true
for phase in "${phases[@]}"; do
    for signal in "${signals[@]}"; do
        for convergence in "${convergences[@]}"; do
            for budget in "${budgets[@]}"; do
                for infra in "${infras[@]}"; do
                    for cancel in "${cancels[@]}"; do
                        reduce "$phase" "$signal" "$convergence" "$budget" "$infra" "$cancel"
                        case "$RLCR_REDUCER_ACTION" in
                            continue_optimize|continue_pivot|continue_closeout|enter_review|terminal_success|terminal_exhausted|terminal_budget|terminal_blocked|terminal_cancelled) ;;
                            *) matrix_ok=false ;;
                        esac
                        [[ -n "$RLCR_REDUCER_NEXT_PHASE" ]] || matrix_ok=false
                        if ! rlcr_reviewer_signal_reachable "$phase" "$signal" \
                           && [[ "$RLCR_REDUCER_ACTION" != terminal_blocked ]]; then
                            matrix_ok=false
                        fi
                    done
                done
            done
        done
    done
done
unset RLCR_REDUCER_NO_OUTPUT
if [[ "$matrix_ok" == true ]]; then
    pass "5-phase full declared-domain matrix is total"
else
    fail "5-phase full declared-domain matrix is total"
fi

# The ID is stable and its exact fixture changes with every required field.
DIGEST=$(printf 'a%.0s' {1..64})
ACTION_ID=$(rlcr_action_id runA 7 3 implementation "$DIGEST" continue_optimize "$RLCR_REDUCER_VERSION")
id_inputs=(
    "runB 7 3 implementation $DIGEST continue_optimize $RLCR_REDUCER_VERSION"
    "runA 8 3 implementation $DIGEST continue_optimize $RLCR_REDUCER_VERSION"
    "runA 7 4 implementation $DIGEST continue_optimize $RLCR_REDUCER_VERSION"
    "runA 7 3 review $DIGEST continue_optimize $RLCR_REDUCER_VERSION"
    "runA 7 3 implementation $(printf 'b%.0s' {1..64}) continue_optimize $RLCR_REDUCER_VERSION"
    "runA 7 3 implementation $DIGEST continue_pivot $RLCR_REDUCER_VERSION"
    "runA 7 3 implementation $DIGEST continue_optimize rlcr-reducer-v2"
)
ids_distinct=true
for input in "${id_inputs[@]}"; do
    # Fixture values contain no spaces; split is intentional for positional API coverage.
    read -r -a fields <<< "$input"
    [[ "$(rlcr_action_id "${fields[@]}")" != "$ACTION_ID" ]] || ids_distinct=false
done
if [[ "$ACTION_ID" == e7eb006529c6a81f88d4cd9d53d42586bc80b546f234413b2edf8896aa0dd128 \
   && "$ACTION_ID" =~ ^[0-9a-f]{64}$ && "$ids_distinct" == true ]]; then
    pass "action_id uses exact versioned digest-bound canonical fixture"
else
    fail "action_id canonical fixture" "id=$ACTION_ID distinct=$ids_distinct"
fi

# New inflight reservations are bound to one host boot.  A copied record from
# another boot/host is malformed for recovery and must fail closed before any
# PID/PGID termination attempt.
IDENTITY_LOOP="$TEST_DIR/identity-loop"
mkdir -p "$IDENTITY_LOOP"
IDENTITY_RESERVATION="reservation-$(printf 'c%.0s' {1..64})"
rlcr_inflight_write_locked "$IDENTITY_LOOP" "$IDENTITY_RESERVATION" 0
IDENTITY_BOOT=$(rlcr_metadata_value "$IDENTITY_LOOP/.action-inflight" boot_identity)
IDENTITY_VALID=false
rlcr_inflight_record_valid "$IDENTITY_LOOP/.action-inflight" && IDENTITY_VALID=true
sed -i.bak 's/^boot_identity=.*/boot_identity=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
    "$IDENTITY_LOOP/.action-inflight"
IDENTITY_MISMATCH_REJECTED=false
if ! rlcr_inflight_record_valid "$IDENTITY_LOOP/.action-inflight"; then
    IDENTITY_MISMATCH_REJECTED=true
fi
if [[ "$IDENTITY_BOOT" =~ ^[0-9a-f]{64}$ && "$IDENTITY_VALID" == true \
   && "$IDENTITY_MISMATCH_REJECTED" == true ]]; then
    pass "inflight identity is bound to the current host boot"
else
    fail "inflight host-boot identity" \
        "boot=$IDENTITY_BOOT valid=$IDENTITY_VALID mismatch_rejected=$IDENTITY_MISMATCH_REJECTED"
fi

# Consumer failure modes are data, never nonzero hook-runtime failures.
PROJECT="$TEST_DIR/project"
LOOP_DIR="$PROJECT/.humanize/rlcr/run-w4b"
mkdir -p "$PROJECT/.pipeline" "$PROJECT/bench" "$LOOP_DIR"
cat > "$PROJECT/.pipeline/state.json" <<EOF
{
  "task_dir": "$PROJECT",
  "stage": "execute",
  "loop_mode": "rlcr",
  "rlcr_control": {
    "schema_version": "rlcr-control-v1",
    "enabled": true,
    "reducer_version": "$RLCR_REDUCER_VERSION",
    "convergence_path": "convergence.json",
    "convergence_evaluator": "bench/promotion_evaluator.py",
    "freshness_bindings": ".pipeline/promotion-freshness.json"
  }
}
EOF
printf '{"loop_mode":"rlcr","reducer_version":"%s"}\n' "$RLCR_REDUCER_VERSION" \
    > "$PROJECT/.pipeline/loop_provenance.json"

RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_evaluate "$PROJECT" "$LOOP_DIR" implementation none
INITIAL_MISSING_STATUS="$RLCR_CONVERGENCE_STATUS"
INITIAL_MISSING_DIGEST="$RLCR_CONVERGENCE_DIGEST"
printf '%s\n' '{"loop_mode":"goal","reducer_version":"tampered","convergence_evaluator":"solution/project/evil.py"}' \
    > "$PROJECT/.pipeline/loop_provenance.json"
TAMPERED_CONTROL_ACTIVE=false
rlcr_control_enabled "$PROJECT" && TAMPERED_CONTROL_ACTIVE=true
TAMPERED_EVALUATOR=$(rlcr_control_config_value "$PROJECT" convergence_evaluator)
rm -f "$PROJECT/.pipeline/loop_provenance.json"
RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_evaluate "$PROJECT" "$LOOP_DIR" implementation none
if [[ "$INITIAL_MISSING_STATUS" == missing \
   && "$INITIAL_MISSING_DIGEST" =~ ^[0-9a-f]{64}$ \
   && "$TAMPERED_CONTROL_ACTIVE" == true \
   && "$TAMPERED_EVALUATOR" == bench/promotion_evaluator.py \
   && "$RLCR_CONTROL_ACTIVE" == true \
   && "$RLCR_CONVERGENCE_STATUS" == missing ]]; then
    pass "missing convergence and marker tamper/delete stay fail-closed"
else
    fail "missing convergence or marker fail-closed mapping" \
        "initial=$INITIAL_MISSING_STATUS/$INITIAL_MISSING_DIGEST tampered=$TAMPERED_CONTROL_ACTIVE/$TAMPERED_EVALUATOR deleted=$RLCR_CONTROL_ACTIVE/$RLCR_CONVERGENCE_STATUS"
fi

cat > "$PROJECT/bench/fail-evaluator" <<'EOF'
#!/usr/bin/env bash
exit 17
EOF
chmod +x "$PROJECT/bench/fail-evaluator"
RLCR_REDUCER_ENABLED=true RLCR_CONVERGENCE_EVALUATOR=bench/fail-evaluator \
    rlcr_control_evaluate "$PROJECT" "$LOOP_DIR" implementation none
if [[ "$RLCR_CONVERGENCE_STATUS" == evaluator_error \
   && "$RLCR_CONVERGENCE_REASON" == evaluator_exit_17 ]]; then
    pass "evaluator nonzero exit becomes evaluator_error data"
else
    fail "evaluator nonzero mapping" "$RLCR_CONVERGENCE_STATUS/$RLCR_CONVERGENCE_REASON"
fi

python3 - "$PROJECT/convergence.json" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = {
    "schema_version": "kop-convergence-v1",
    "status": "pass",
    "promotion_evaluated": True,
    "success": True,
    "eligibility": {
        "evidence_freshness_valid": True,
        "tcb_digests_valid": True,
    },
}
payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
value["convergence_digest"] = hashlib.sha256(payload).hexdigest()
path.write_text(json.dumps(value) + "\n", encoding="utf-8")
PY
RLCR_REDUCER_ENABLED=true RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_evaluate "$PROJECT" "$LOOP_DIR" implementation COMPLETE
VALID_DIGEST="$RLCR_CONVERGENCE_DIGEST"
if [[ "$RLCR_CONVERGENCE_STATUS" == pass && "$VALID_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    pass "valid convergence digest is consumed"
else
    fail "valid convergence consumption" "$RLCR_CONVERGENCE_STATUS/$RLCR_CONVERGENCE_REASON"
fi
python3 - "$PROJECT/convergence.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["success"] = False
path.write_text(json.dumps(value) + "\n")
PY
RLCR_REDUCER_ENABLED=true RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_evaluate "$PROJECT" "$LOOP_DIR" implementation COMPLETE
if [[ "$RLCR_CONVERGENCE_STATUS" == stale \
   && "$RLCR_CONVERGENCE_REASON" == convergence_digest_stale ]]; then
    pass "stale convergence digest maps to blocked input"
else
    fail "stale convergence mapping" "$RLCR_CONVERGENCE_STATUS/$RLCR_CONVERGENCE_REASON"
fi

# Restore the valid document and prove finalize candidate changes require a
# new convergence digest, while a genuinely new digest may finish closeout.
python3 - "$PROJECT/convergence.json" <<'PY'
import hashlib, json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = {
    "schema_version": "kop-convergence-v1",
    "status": "pass",
    "promotion_evaluated": True,
    "success": True,
    "eligibility": {
        "evidence_freshness_valid": True,
        "tcb_digests_valid": True,
    },
}
payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
value["convergence_digest"] = hashlib.sha256(payload).hexdigest()
path.write_text(json.dumps(value) + "\n", encoding="utf-8")
PY
RLCR_REDUCER_ENABLED=true RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_decide "$PROJECT" "$LOOP_DIR" finalize COMPLETE 0 5 1 2 \
    "$VALID_DIGEST" "$(printf 'f%.0s' {1..64})"
if [[ "$RLCR_CONVERGENCE_STATUS" == stale \
   && "$RLCR_REDUCER_ACTION" == terminal_blocked \
   && "$RLCR_CONVERGENCE_REASON" == finalize_changed_candidate_without_new_convergence ]]; then
    pass "finalize candidate change requires fresh convergence digest"
else
    fail "finalize freshness revalidation" "$RLCR_CONVERGENCE_STATUS/$RLCR_REDUCER_ACTION/$RLCR_CONVERGENCE_REASON"
fi
RLCR_REDUCER_ENABLED=true RLCR_CONVERGENCE_CONSUME_ONLY=true \
    rlcr_control_decide "$PROJECT" "$LOOP_DIR" finalize COMPLETE 0 5 1 2 \
    "$(printf 'e%.0s' {1..64})" "$(printf 'f%.0s' {1..64})"
if [[ "$RLCR_CONVERGENCE_STATUS" == pass \
   && "$RLCR_REDUCER_ACTION" == terminal_success ]]; then
    pass "finalize accepts changed candidate only with revalidated digest"
else
    fail "finalize changed candidate revalidation" "$RLCR_CONVERGENCE_STATUS/$RLCR_REDUCER_ACTION/$RLCR_CONVERGENCE_REASON"
fi

# Real Stop-hook integration for the three formerly independent decisions:
# max-iteration, COMPLETE, and normal next-round update.  Codex and evaluator
# are local deterministic stubs; no external model or benchmark is invoked.
STOP_HOOK="$PLUGIN_ROOT/hooks/loop-codex-stop-hook.sh"
MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" exec "*) printf '%s\n' "${W4B_CODEX_OUTPUT:?}" ;;
    *" review "*) printf '%s\n' "${W4B_REVIEW_OUTPUT:-No findings.}" ;;
    *) printf '%s\n' "codex W4b stub" ;;
esac
EOF
chmod +x "$MOCK_BIN/codex"

make_hook_project() {
    local name="$1" round="$2" max_iterations="$3"
    HOOK_PROJECT="$TEST_DIR/hook-$name"
    mkdir -p "$HOOK_PROJECT/bench" "$HOOK_PROJECT/.pipeline"
    git -C "$HOOK_PROJECT" init -q
    git -C "$HOOK_PROJECT" config user.email test@example.com
    git -C "$HOOK_PROJECT" config user.name "W4b Test"
    git -C "$HOOK_PROJECT" config commit.gpgsign false
    cat > "$HOOK_PROJECT/.gitignore" <<'EOF'
.humanize/
.pipeline/
convergence.json
EOF
    cat > "$HOOK_PROJECT/plan.md" <<'EOF'
# W4b hook plan

Exercise the convergence reducer.
Keep the fixture deterministic.
Require review and finalize before success.
EOF
    cat > "$HOOK_PROJECT/bench/w4b-evaluator.py" <<'PY'
#!/usr/bin/env python3
import argparse, hashlib, json, os
if os.environ.get("W4B_EVAL_EXIT", "0") != "0":
    raise SystemExit(int(os.environ["W4B_EVAL_EXIT"]))
parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True)
parser.add_argument("--evidence")
parser.add_argument("--gates")
parser.add_argument("--inputs")
parser.add_argument("--leaderboard")
parser.add_argument("--freshness-bindings")
args = parser.parse_args()
status = os.environ["W4B_EVAL_STATUS"]
passed = status == "pass"
value = {
    "schema_version": "kop-convergence-v1",
    "status": status,
    "promotion_evaluated": True,
    "success": passed,
    "eligibility": {
        "evidence_freshness_valid": True,
        "tcb_digests_valid": True,
    },
}
payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
value["convergence_digest"] = hashlib.sha256(payload).hexdigest()
with open(args.output, "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
PY
    chmod +x "$HOOK_PROJECT/bench/w4b-evaluator.py"
    git -C "$HOOK_PROJECT" add .gitignore plan.md bench/w4b-evaluator.py
    git -C "$HOOK_PROJECT" commit -q -m fixture
    local branch base_commit
    branch=$(git -C "$HOOK_PROJECT" rev-parse --abbrev-ref HEAD)
    base_commit=$(git -C "$HOOK_PROJECT" rev-parse HEAD)
    HOOK_LOOP="$HOOK_PROJECT/.humanize/rlcr/run-$name"
    mkdir -p "$HOOK_LOOP"
    cp "$HOOK_PROJECT/plan.md" "$HOOK_LOOP/plan.md"
    printf '%s' "printf 'W4b fixture full benchmark passed\n'" > "$HOOK_LOOP/benchmark-command.sh"
    printf '%s\n' 10 > "$HOOK_LOOP/benchmark-timeout"
    cat > "$HOOK_LOOP/state.md" <<EOF
---
current_round: $round
max_iterations: $max_iterations
codex_model: test-model
codex_effort: low
codex_timeout: 10
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: true
start_branch: $branch
base_branch: $branch
base_commit: $base_commit
review_started: false
ask_codex_question: false
session_id:
agent_teams: false
privacy_mode: true
bitlesson_required: false
mainline_stall_count: 0
last_mainline_verdict: unknown
drift_status: normal
closeout_steps: 0
max_closeout_steps: 2
last_convergence_digest:
last_candidate_fingerprint:
last_reducer_action:
control_epoch: 1
pending_action_id:
pending_successor_generation:
pending_successor_phase:
ack_action_id:
ack_successor_generation:
ack_successor_phase:
last_applied_action_id:
---
EOF
    printf '1\n' > "$HOOK_LOOP/.control-epoch"
    cat > "$HOOK_LOOP/goal-tracker.md" <<'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Exercise W4b.
### Acceptance Criteria
| ID | Criterion |
|---|---|
| AC-1 | Reducer owns every round decision |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status |
|---|---|---|
| Test | AC-1 | completed |
EOF
    cat > "$HOOK_LOOP/round-${round}-summary.md" <<EOF
# Round $round Summary
The deterministic fixture is committed.
EOF
    cat > "$HOOK_LOOP/round-${round}-contract.md" <<EOF
# Round $round Contract
- Mainline Objective: exercise the W4b reducer
- Target ACs: AC-1
- Blocking Side Issues In Scope: none
- Queued Side Issues Out of Scope: none
- Success Criteria: one canonical reducer action
EOF
    cat > "$HOOK_PROJECT/.pipeline/loop_provenance.json" <<EOF
{
  "loop_mode": "rlcr",
  "reducer_version": "$RLCR_REDUCER_VERSION",
  "convergence_path": "convergence.json",
  "convergence_evaluator": "bench/w4b-evaluator.py",
  "freshness_bindings": ".pipeline/promotion-freshness.json",
  "loop_dir": "$HOOK_LOOP"
}
EOF
}

run_w4b_hook() {
    local output_file="$1" convergence_status="$2" codex_output="$3" evaluator_exit="${4:-0}"
    (cd "$HOOK_PROJECT" && printf '%s' '{"stop_hook_active":false}' | \
        env PATH="$MOCK_BIN:$PATH" CLAUDE_PROJECT_DIR="$HOOK_PROJECT" \
        XDG_CACHE_HOME="$TEST_DIR/cache" W4B_EVAL_STATUS="$convergence_status" \
        W4B_EVAL_EXIT="$evaluator_exit" W4B_CODEX_OUTPUT="$codex_output" "$STOP_HOOK") \
        > "$output_file" 2> "${output_file}.err"
}

make_hook_project complete 0 5
run_w4b_hook "$TEST_DIR/hook-complete.json" pass $'Mainline Progress Verdict: ADVANCED\n\nCOMPLETE'
COMPLETE_ACTION=$(jq -r '.action.payload.kind // empty' "$TEST_DIR/hook-complete.json")
COMPLETE_ID=$(jq -r '.action_id // empty' "$TEST_DIR/hook-complete.json")
COMPLETE_DIGEST=$(jq -r '.convergence_digest' "$HOOK_PROJECT/convergence.json")
EXPECTED_COMPLETE_ID=$(rlcr_action_id run-complete 1 0 implementation \
    "$COMPLETE_DIGEST" enter_review "$RLCR_REDUCER_VERSION")
if [[ "$COMPLETE_ACTION" == enter_review && "$COMPLETE_ID" == "$EXPECTED_COMPLETE_ID" \
   && "$(sed -n 's/^review_started:[[:space:]]*//p' "$HOOK_LOOP/state.md")" == true ]]; then
    pass "Stop hook COMPLETE path uses reducer and exact action_id"
else
    fail "Stop hook COMPLETE reducer path" "action=$COMPLETE_ACTION id=$COMPLETE_ID/$EXPECTED_COMPLETE_ID err=$(tail -5 "$TEST_DIR/hook-complete.json.err")"
fi

make_hook_project next 0 5
run_w4b_hook "$TEST_DIR/hook-next.json" below_target $'Mainline Progress Verdict: ADVANCED\n\nCONTINUE'
if [[ "$(jq -r '.action.payload.kind // empty' "$TEST_DIR/hook-next.json")" == continue_optimize \
   && "$(sed -n 's/^current_round:[[:space:]]*//p' "$HOOK_LOOP/state.md")" == 1 ]]; then
    pass "Stop hook next-round path uses convergence reducer"
else
    fail "Stop hook next-round reducer path" "out=$(cat "$TEST_DIR/hook-next.json") err=$(tail -5 "$TEST_DIR/hook-next.json.err")"
fi

make_hook_project max 0 0
run_w4b_hook "$TEST_DIR/hook-max.json" below_target $'Mainline Progress Verdict: ADVANCED\n\nCONTINUE'
if [[ "$(jq -r '.action.payload.kind // empty' "$TEST_DIR/hook-max.json")" == terminal_budget \
   && -f "$HOOK_LOOP/maxiter-state.md" && ! -f "$HOOK_LOOP/state.md" ]]; then
    pass "Stop hook max-iteration path uses convergence reducer"
else
    fail "Stop hook max-iteration reducer path" "out=$(cat "$TEST_DIR/hook-max.json") files=$(find "$HOOK_LOOP" -maxdepth 1 -type f -printf '%f ' 2>/dev/null) err=$(tail -5 "$TEST_DIR/hook-max.json.err")"
fi

make_hook_project evaluator-failure 0 5
run_w4b_hook "$TEST_DIR/hook-evaluator-failure.json" pass \
    $'Mainline Progress Verdict: ADVANCED\n\nCONTINUE' 23
if [[ "$(jq -r '.action.payload.kind // empty' "$TEST_DIR/hook-evaluator-failure.json")" == terminal_blocked \
   && -f "$HOOK_LOOP/blocked-state.md" && ! -f "$HOOK_LOOP/state.md" ]]; then
    pass "Stop hook evaluator nonzero becomes terminal_blocked action"
else
    fail "Stop hook evaluator nonzero mapping" "out=$(cat "$TEST_DIR/hook-evaluator-failure.json") err=$(tail -8 "$TEST_DIR/hook-evaluator-failure.json.err")"
fi

printf '\nW4b reducer tests: %d passed, %d failed\n' "$PASSED" "$FAILED"
printf 'Passed: %d\nFailed: %d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
