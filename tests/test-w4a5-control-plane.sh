#!/usr/bin/env bash
# Reproducible W4a.5 acceptance tests.  Every fixture is isolated under mktemp;
# Codex is always a PATH stub and no repository-local RLCR state is used.

set -uo pipefail

TEST_DIR="$(mktemp -d)"
if [[ "${RLCR_TEST_KEEP_DIR:-0}" == "1" ]]; then
    trap 'printf "Preserved test fixture: %s\n" "$TEST_DIR"' EXIT
else
    trap 'rm -rf "$TEST_DIR"' EXIT
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_LIB="$PLUGIN_ROOT/hooks/lib/loop-state-write.sh"
STOP_HOOK="$PLUGIN_ROOT/hooks/loop-codex-stop-hook.sh"
POST_HOOK="$PLUGIN_ROOT/hooks/loop-post-bash-hook.sh"
SETUP_SCRIPT="$PLUGIN_ROOT/scripts/setup-rlcr-loop.sh"
CANCEL_LOOP="$PLUGIN_ROOT/scripts/cancel-rlcr-loop.sh"
CANCEL_SESSION="$PLUGIN_ROOT/scripts/cancel-rlcr-session.sh"
STOP_GATE="$PLUGIN_ROOT/scripts/rlcr-stop-gate.sh"
BENCHMARK_COMMAND="printf 'W4a.5 fixture full benchmark passed\n'"
BENCHMARK_TIMEOUT=10

PASSED=0
FAILED=0
pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '\033[0;31mFAIL\033[0m: %s\n  %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); }
process_can_write() {
    local pid="$1" stat_line stat_rest state
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    stat_rest="${stat_line##*) }"
    state="${stat_rest%% *}"
    [[ "$state" != "Z" && "$state" != "X" ]]
}

MOCK_BIN="$TEST_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
pid_can_write() {
    local pid="$1" stat_line stat_rest state
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    stat_rest="${stat_line##*) }"
    state="${stat_rest%% *}"
    [[ "$state" != "Z" && "$state" != "X" ]]
}
kind=""
for arg in "$@"; do
    case "$arg" in exec|review) kind="$arg"; break ;; esac
done
if [[ -z "$kind" ]]; then
    # Feature probing intentionally sees no --disable support.
    [[ "${1:-}" == "--help" ]] && echo "codex test stub"
    exit 0
fi
printf '%s\n' "$kind" >> "${CODEX_CALL_LOG:?}"
if [[ -n "${CODEX_LOCK_SCOPE:-}" && -d "$CODEX_LOCK_SCOPE/.rlcr-control.lock" ]]; then
    printf 'LOCKED\n' >> "${CODEX_LOCK_LOG:?}"
fi
if [[ -n "${CODEX_REVIEWER_PID_LOG:-}" ]]; then
    while IFS= read -r prior_pid; do
        if [[ "$prior_pid" =~ ^[0-9]+$ && "$prior_pid" != "$$" ]] \
           && pid_can_write "$prior_pid"; then
            printf '%s overlaps %s\n' "$$" "$prior_pid" >> "${CODEX_OVERLAP_LOG:?}"
        fi
    done < "$CODEX_REVIEWER_PID_LOG"
    printf '%s\n' "$$" >> "$CODEX_REVIEWER_PID_LOG"
    [[ -z "${CODEX_WORKTREE_LOG:-}" ]] \
        || printf 'START %s\n' "$$" >> "$CODEX_WORKTREE_LOG"
fi
if [[ -n "${CODEX_BLOCK_ONCE_DIR:-}" ]] && mkdir "$CODEX_BLOCK_ONCE_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "${CODEX_STUB_STARTED_FILE:?}"
    mkfifo "$CODEX_BLOCK_ONCE_DIR/gate"
    exec 9<> "$CODEX_BLOCK_ONCE_DIR/gate"
    IFS= read -r -t 300 _codex_release <&9 || true
    exec 9>&-
fi
sleep "${CODEX_STUB_SLEEP:-0}"
[[ -z "${CODEX_WORKTREE_LOG:-}" ]] \
    || printf 'END %s\n' "$$" >> "$CODEX_WORKTREE_LOG"
if [[ "$kind" == "review" ]]; then
    printf '%s\n' "${CODEX_REVIEW_OUTPUT:-No issues found.}"
else
    printf '%s\n' "${CODEX_EXEC_OUTPUT:-Mainline Progress Verdict: ADVANCED}"
    suffix="${CODEX_EXEC_SUFFIX-CONTINUE}"
    if [[ -n "$suffix" ]]; then
        printf '\n%s\n' "$suffix"
    fi
fi
exit 0
MOCK_CODEX
chmod +x "$MOCK_BIN/codex"
export PATH="$MOCK_BIN:$PATH"

if [[ "$(command -v codex)" != "$MOCK_BIN/codex" ]]; then
    echo "FAIL: real Codex would be reachable; refusing to run" >&2
    exit 1
fi

new_project() {
    local name="$1"
    PROJECT="$TEST_DIR/$name/project"
    mkdir -p "$PROJECT"
    git -C "$PROJECT" init -q
    git -C "$PROJECT" config user.email test@example.com
    git -C "$PROJECT" config user.name "W4a.5 Test"
    git -C "$PROJECT" config commit.gpgsign false
    cat > "$PROJECT/.gitignore" <<'EOF'
.humanize/
EOF
    cat > "$PROJECT/plan.md" <<'EOF'
# Test Plan

Implement the isolated control-plane fixture.
Preserve exactly-once logical generation.
Keep cancellation terminal.
Exercise the real hook scripts.
EOF
    git -C "$PROJECT" add .gitignore plan.md
    git -C "$PROJECT" commit -q -m init
    BRANCH=$(git -C "$PROJECT" rev-parse --abbrev-ref HEAD)
    BASE_COMMIT=$(git -C "$PROJECT" rev-parse HEAD)
}

make_loop() {
    local project="$1" sid="$2" round="${3:-0}" max="${4:-5}" privacy="${5:-true}"
    LOOP_DIR="$project/.humanize/rlcr/$sid"
    mkdir -p "$LOOP_DIR"
    cp "$project/plan.md" "$LOOP_DIR/plan.md"
    printf '%s' "$BENCHMARK_COMMAND" > "$LOOP_DIR/benchmark-command.sh"
    printf '%s\n' "$BENCHMARK_TIMEOUT" > "$LOOP_DIR/benchmark-timeout"
    cat > "$LOOP_DIR/state.md" <<EOF
---
current_round: $round
max_iterations: $max
codex_model: test-model
codex_effort: low
codex_timeout: 10
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: true
start_branch: $BRANCH
base_branch: $BRANCH
base_commit: $BASE_COMMIT
review_started: false
ask_codex_question: false
session_id:
agent_teams: false
privacy_mode: $privacy
mainline_stall_count: 0
last_mainline_verdict: unknown
drift_status: normal
control_epoch: 0
pending_action_id:
ack_action_id:
last_applied_action_id:
---
EOF
    printf '0\n' > "$LOOP_DIR/.control-epoch"
    cat > "$LOOP_DIR/goal-tracker.md" <<'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Exercise W4a.5.
### Acceptance Criteria
| ID | Criterion |
|---|---|
| AC-1 | Control-plane test passes |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status |
|---|---|---|
| Test | AC-1 | completed |
EOF
    cat > "$LOOP_DIR/round-${round}-summary.md" <<EOF
# Round $round Summary
All isolated fixture work is committed.
EOF
    cat > "$LOOP_DIR/round-${round}-contract.md" <<EOF
# Round $round Contract
- Mainline Objective: exercise W4a.5
- Target ACs: AC-1
- Blocking Side Issues In Scope: none
- Queued Side Issues Out of Scope: none
- Success Criteria: hook returns canonical action
EOF
}

run_hook() {
    local project="$1" output="$2"
    shift 2
    (cd "$project" && printf '%s' '{"stop_hook_active":false}' | \
        env CLAUDE_PROJECT_DIR="$project" XDG_CACHE_HOME="$TEST_DIR/cache" "$@" \
        "$STOP_HOOK") > "$output" 2> "${output}.err"
}

echo "=== W4a.5 RLCR Control-Plane Acceptance ==="

# AC-1 / F-1: structured schema rejects whitespace injection and undeclared fields.
AC1="$TEST_DIR/ac1/rlcr/session"
mkdir -p "$AC1"
cat > "$AC1/state.md" <<'EOF'
---
current_round: 0
max_iterations: 5
review_started: false
base_branch: main
---
EOF
source "$STATE_LIB"
if rlcr_state_update "$AC1/state.md" "ack_action_id=gen7 phase=review" 2>/dev/null; then
    fail "AC-1 F-1 whitespace injection rejected" "writer accepted an unsafe value"
elif grep -q '^phase:' "$AC1/state.md" || grep -q '^ack_action_id:' "$AC1/state.md"; then
    fail "AC-1 F-1 whitespace injection rejected" "state gained an injected/partial field"
else
    pass "AC-1 F-1 whitespace injection rejected without undeclared fields"
fi
if rlcr_state_update "$AC1/state.md" "not_in_schema=value" 2>/dev/null; then
    fail "AC-1 formal state schema" "undeclared field was accepted"
else
    pass "AC-1 formal state schema rejects undeclared writes"
fi

# AC-2 / F-2: concurrent session cancel and real PostToolUse cannot resurrect state.md.
new_project ac2
make_loop "$PROJECT" 2026-08-09_00-00-02
printf '%s\n%s\n' "$LOOP_DIR/state.md" "$SETUP_SCRIPT" > "$PROJECT/.humanize/.pending-session-id"
POST_JSON=$(jq -n --arg cmd "$SETUP_SCRIPT plan.md" --arg cwd "$PROJECT" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd,session_id:"session-ac2"}')
(printf '%s' "$POST_JSON" | CLAUDE_PROJECT_DIR="$PROJECT" "$POST_HOOK") & POST_PID=$!
(CLAUDE_PROJECT_DIR="$PROJECT" "$CANCEL_SESSION" --project "$PROJECT" --session-id "$(basename "$LOOP_DIR")" >/dev/null) & CANCEL_PID=$!
wait "$POST_PID" || true
wait "$CANCEL_PID" || true
if [[ -f "$LOOP_DIR/cancel-state.md" && ! -f "$LOOP_DIR/state.md" ]]; then
    pass "AC-2 F-2 cancel + PostToolUse cannot recreate state.md"
else
    fail "AC-2 F-2 cancel + PostToolUse" "state files: $(find "$LOOP_DIR" -maxdepth 1 -name '*state.md' -print)"
fi

# AC-3 / F-3: gate and native Stop share one generation and canonical action.
new_project ac3
make_loop "$PROJECT" 2026-08-09_00-00-03
export CODEX_CALL_LOG="$TEST_DIR/ac3-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac3-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_STUB_SLEEP=0.6
export CODEX_EXEC_OUTPUT="Mainline Progress Verdict: ADVANCED"
export CODEX_EXEC_SUFFIX=CONTINUE
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
(run_hook "$PROJECT" "$TEST_DIR/ac3-native.json") & NATIVE_PID=$!
(cd "$PROJECT" && CLAUDE_PROJECT_DIR="$PROJECT" XDG_CACHE_HOME="$TEST_DIR/cache" \
    "$STOP_GATE" --project-root "$PROJECT" --json > "$TEST_DIR/ac3-gate.json" 2> "$TEST_DIR/ac3-gate.err") & GATE_PID=$!
wait "$NATIVE_PID" || true
wait "$GATE_PID" || true
AC3_EXEC_COUNT=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
AC3_ROUND=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
AC3_NATIVE_ID=$(jq -r '.action_id // empty' "$TEST_DIR/ac3-native.json" 2>/dev/null || true)
AC3_GATE_ID=$(jq -r '.action_id // empty' "$TEST_DIR/ac3-gate.json" 2>/dev/null || true)
if [[ "$AC3_EXEC_COUNT" == "1" && "$AC3_ROUND" == "1" && -n "$AC3_NATIVE_ID" && "$AC3_NATIVE_ID" == "$AC3_GATE_ID" ]]; then
    pass "AC-3 F-3 one Codex, one generation commit, one canonical action"
else
    fail "AC-3 F-3 concurrent gate/native Stop" "exec=$AC3_EXEC_COUNT round=$AC3_ROUND native=$AC3_NATIVE_ID gate=$AC3_GATE_ID"
fi

# T1 / AC-3b: kill the real Stop hook while its Codex reviewer is blocked.
# Recovery may replace the aborted reviewer only after mechanically proving the
# persisted reviewer process group is gone.  The stub records a concrete
# overlap if a second writer starts while the first reviewer PID is still live.
new_project ac3_orphan_reviewer
make_loop "$PROJECT" 2026-08-09_00-00-03b
export CODEX_CALL_LOG="$TEST_DIR/ac3-orphan-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac3-orphan-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_REVIEWER_PID_LOG="$TEST_DIR/ac3-orphan-reviewer-pids.log"
export CODEX_OVERLAP_LOG="$TEST_DIR/ac3-orphan-overlap.log"
export CODEX_WORKTREE_LOG="$PROJECT/reviewer-window.log"
printf 'reviewer-window.log\n' >> "$PROJECT/.git/info/exclude"
export CODEX_BLOCK_ONCE_DIR="$TEST_DIR/ac3-orphan-block-once"
export CODEX_STUB_STARTED_FILE="$TEST_DIR/ac3-orphan-started"
export CODEX_STUB_SLEEP=0
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
: > "$CODEX_REVIEWER_PID_LOG"; : > "$CODEX_OVERLAP_LOG"
(run_hook "$PROJECT" "$TEST_DIR/ac3-orphan-killed.json") & ORPHAN_WRAPPER_PID=$!
for _wait_tick in $(seq 1 500); do
    [[ -s "$CODEX_STUB_STARTED_FILE" ]] && break
    sleep 0.01
done
ORPHAN_HOOK_PID=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" pid)
ORPHAN_REVIEWER_PID=$(sed -n '1p' "$CODEX_STUB_STARTED_FILE" 2>/dev/null || true)
ORPHAN_REVIEWER_PGID=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" reviewer_pgid)
ORPHAN_WORKER_ID=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" reviewer_worker_id)
ORPHAN_START_TICKS=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" reviewer_start_ticks)
ORPHAN_PROTOCOL=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" reviewer_protocol)
ORPHAN_REVIEWER_STATE=$(rlcr_metadata_value "$LOOP_DIR/.action-inflight" reviewer_state)
ORPHAN_PAYLOAD_PGID=""; ORPHAN_PAYLOAD_SESSION=""; _ORPHAN_PAYLOAD_START=""
read -r ORPHAN_PAYLOAD_PGID ORPHAN_PAYLOAD_SESSION _ORPHAN_PAYLOAD_START \
    < <(rlcr_proc_identity "$ORPHAN_REVIEWER_PID" 2>/dev/null || true)
if [[ "$ORPHAN_HOOK_PID" =~ ^[0-9]+$ ]]; then
    kill -9 "$ORPHAN_HOOK_PID" 2>/dev/null || true
fi
wait "$ORPHAN_WRAPPER_PID" 2>/dev/null || true
ORPHAN_WAS_LIVE=0
if process_can_write "$ORPHAN_REVIEWER_PID"; then
    ORPHAN_WAS_LIVE=1
fi
run_hook "$PROJECT" "$TEST_DIR/ac3-orphan-recovered.json" \
    RLCR_LOCK_LEASE_SECONDS=0 RLCR_ACTION_RETRY_SECONDS=0.01 || true
for _wait_tick in $(seq 1 200); do
    if ! process_can_write "$ORPHAN_REVIEWER_PID"; then
        break
    fi
    sleep 0.01
done
ORPHAN_OLD_DEAD=0
process_can_write "$ORPHAN_REVIEWER_PID" || ORPHAN_OLD_DEAD=1
ORPHAN_EXEC_COUNT=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
ORPHAN_ROUND=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ "$ORPHAN_WAS_LIVE" == "1" && "$ORPHAN_OLD_DEAD" == "1" \
      && "$ORPHAN_EXEC_COUNT" == "2" && "$ORPHAN_ROUND" == "1" \
      && -n "$ORPHAN_REVIEWER_PGID" && -n "$ORPHAN_WORKER_ID" \
      && -n "$ORPHAN_START_TICKS" && "$ORPHAN_PROTOCOL" == "pgid-v1" \
      && "$ORPHAN_REVIEWER_STATE" == "registered" \
      && "$ORPHAN_PAYLOAD_PGID" == "$ORPHAN_REVIEWER_PGID" \
      && "$ORPHAN_PAYLOAD_SESSION" == "$ORPHAN_REVIEWER_PGID" \
      && ! -s "$CODEX_OVERLAP_LOG" ]]; then
    pass "T1 orphan reviewer is terminated and proven dead before recovery Codex starts"
else
    fail "T1 SIGKILL-during-Codex orphan exclusion" \
        "hook=$ORPHAN_HOOK_PID reviewer=$ORPHAN_REVIEWER_PID live_before=$ORPHAN_WAS_LIVE dead_after=$ORPHAN_OLD_DEAD exec=$ORPHAN_EXEC_COUNT round=$ORPHAN_ROUND pgid=$ORPHAN_REVIEWER_PGID payload_group=$ORPHAN_PAYLOAD_PGID/$ORPHAN_PAYLOAD_SESSION protocol=$ORPHAN_PROTOCOL state=$ORPHAN_REVIEWER_STATE worker=$ORPHAN_WORKER_ID start=$ORPHAN_START_TICKS overlap=$(cat "$CODEX_OVERLAP_LOG") recovery_err=$(tail -10 "$TEST_DIR/ac3-orphan-recovered.json.err")"
fi
# Old implementations intentionally leave the first stub alive.  Bound local
# cleanup prevents the red-before-fix run from leaking the test payload.
if kill -0 "$ORPHAN_REVIEWER_PID" 2>/dev/null; then
    kill -9 "$ORPHAN_REVIEWER_PID" 2>/dev/null || true
fi
unset CODEX_REVIEWER_PID_LOG CODEX_OVERLAP_LOG CODEX_WORKTREE_LOG
unset CODEX_BLOCK_ONCE_DIR CODEX_STUB_STARTED_FILE

# R4 / V1-V3: a non-action writer must not advance the epoch and let recovery
# replace an action while the old reviewer session can still write.  Reproduce
# the reviewed failure with a real two-process setsid group and a dead hook
# owner.  Either the writer/recovery terminates the group before returning a
# leader, or one of them must fail closed with status 4.
new_project r4_epoch_mismatch
make_loop "$PROJECT" 2026-08-09_00-00-03c
R4_GROUP_READY="$TEST_DIR/r4-epoch-group.ready"
env RLCR_REVIEWER_WORKER_ID=r4-epoch-worker \
    setsid bash -c 'trap "" TERM; sleep 300 & child=$!; printf "%s %s\n" "$$" "$child" > "$1"; wait' \
    _ "$R4_GROUP_READY" &
R4_GROUP_LAUNCHER=$!
for _wait_tick in $(seq 1 500); do
    [[ -s "$R4_GROUP_READY" ]] && break
    sleep 0.01
done
read -r R4_REVIEWER_PID R4_REVIEWER_CHILD < "$R4_GROUP_READY"
R4_REVIEWER_PGID=""; R4_REVIEWER_SESSION=""; R4_REVIEWER_START=""
read -r R4_REVIEWER_PGID R4_REVIEWER_SESSION R4_REVIEWER_START \
    < <(rlcr_proc_identity "$R4_REVIEWER_PID" 2>/dev/null || true)
cat > "$LOOP_DIR/.action-inflight" <<EOF
action_id=gen-1-impl-0
epoch=0
pid=99999999
hook_start_ticks=1
started=$(rlcr_now_epoch)
reviewer_protocol=pgid-v1
reviewer_state=registered
reviewer_worker_id=r4-epoch-worker
reviewer_pid=$R4_REVIEWER_PID
reviewer_pgid=$R4_REVIEWER_PGID
reviewer_start_ticks=$R4_REVIEWER_START
EOF
R4_LIVE_BEFORE=0
if process_can_write "$R4_REVIEWER_PID" && process_can_write "$R4_REVIEWER_CHILD"; then
    R4_LIVE_BEFORE=1
fi
R4_WRITER_STATUS=0
rlcr_state_update "$LOOP_DIR/state.md" "current_round=0" 2>/dev/null || R4_WRITER_STATUS=$?
R4_EPOCH_AFTER_WRITER=$(rlcr_epoch_read "$LOOP_DIR")
R4_ACTION_STATUS=0
rlcr_action_begin "$PROJECT/.humanize/rlcr" "$LOOP_DIR" impl 0 2>/dev/null || R4_ACTION_STATUS=$?
R4_GROUP_LIVE_AFTER=0
if process_can_write "$R4_REVIEWER_PID" || process_can_write "$R4_REVIEWER_CHILD"; then
    R4_GROUP_LIVE_AFTER=1
fi
if [[ "$R4_LIVE_BEFORE" == "1" \
      && ( "$R4_WRITER_STATUS" == "0" || "$R4_WRITER_STATUS" == "4" ) \
      && ( "$R4_ACTION_STATUS" == "0" || "$R4_ACTION_STATUS" == "4" ) \
      && ( "$R4_WRITER_STATUS" != "4" || "$R4_EPOCH_AFTER_WRITER" == "0" ) \
      && ( "$R4_ACTION_STATUS" != "0" || "$R4_GROUP_LIVE_AFTER" == "0" ) ]]; then
    pass "R4 V1-V3 epoch writer/recovery cannot return leader over a live old reviewer group"
else
    fail "R4 V1-V3 epoch-mismatch reviewer exclusion" \
        "live_before=$R4_LIVE_BEFORE writer=$R4_WRITER_STATUS epoch=$R4_EPOCH_AFTER_WRITER action=$R4_ACTION_STATUS action_id=$RLCR_ACTION_ID live_after=$R4_GROUP_LIVE_AFTER pgid=$R4_REVIEWER_PGID/$R4_REVIEWER_SESSION"
fi
kill -KILL -- "-$R4_REVIEWER_PGID" 2>/dev/null || true
wait "$R4_GROUP_LAUNCHER" 2>/dev/null || true

# A live foreign action owner can still move none->prepared->fork after an
# instantaneous scan, so a non-action writer must return 4 without advancing.
new_project r4_live_owner
make_loop "$PROJECT" 2026-08-09_00-00-03m
sleep 300 &
R4_OWNER_PID=$!
R4_OWNER_GROUP=""; R4_OWNER_SESSION=""; R4_OWNER_START=""
read -r R4_OWNER_GROUP R4_OWNER_SESSION R4_OWNER_START \
    < <(rlcr_proc_identity "$R4_OWNER_PID" 2>/dev/null || true)
cat > "$LOOP_DIR/.action-inflight" <<EOF
action_id=gen-1-impl-0
epoch=0
pid=$R4_OWNER_PID
hook_start_ticks=$R4_OWNER_START
started=$(rlcr_now_epoch)
reviewer_protocol=pgid-v1
reviewer_state=none
EOF
R4_LIVE_OWNER_STATUS=0
rlcr_state_update "$LOOP_DIR/state.md" "current_round=0" 2>/dev/null \
    || R4_LIVE_OWNER_STATUS=$?
R4_LIVE_OWNER_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")
if [[ "$R4_LIVE_OWNER_STATUS" == "4" && "$R4_LIVE_OWNER_EPOCH" == "0" \
      && -f "$LOOP_DIR/.action-inflight" ]]; then
    pass "R4 V1 live foreign action owner fences non-action epoch writer"
else
    fail "R4 V1 live-owner writer fence" \
        "status=$R4_LIVE_OWNER_STATUS epoch=$R4_LIVE_OWNER_EPOCH inflight=$([[ -f "$LOOP_DIR/.action-inflight" ]] && echo yes || echo no)"
fi
kill -KILL "$R4_OWNER_PID" 2>/dev/null || true
wait "$R4_OWNER_PID" 2>/dev/null || true

# R4 / V4: one uninspectable stat entry makes an otherwise empty scan UNKNOWN,
# never EMPTY.  The proc-root function is overridden only inside this fixture;
# production always supplies /proc.
R4_PROC_ROOT="$TEST_DIR/r4-proc"
setsid sleep 300 &
R4_PROC_GROUP_LAUNCHER=$!
R4_PROC_GROUP=""; R4_PROC_SESSION=""; R4_PROC_START=""
for _wait_tick in $(seq 1 200); do
    read -r R4_PROC_GROUP R4_PROC_SESSION R4_PROC_START \
        < <(rlcr_proc_identity "$R4_PROC_GROUP_LAUNCHER" 2>/dev/null || true)
    [[ -n "$R4_PROC_GROUP" && "$R4_PROC_GROUP" == "$R4_PROC_SESSION" ]] && break
    sleep 0.01
done
mkdir -p "$R4_PROC_ROOT/101" "$R4_PROC_ROOT/$R4_PROC_GROUP/stat"
printf '101 (readable) S 1 101 101 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 77\n' \
    > "$R4_PROC_ROOT/101/stat"
rlcr_proc_root() { printf '%s\n' "$R4_PROC_ROOT"; }
R4_PROC_STATUS=0
rlcr_reviewer_group_live "$R4_PROC_GROUP" 2>/dev/null || R4_PROC_STATUS=$?
unset -f rlcr_proc_root
kill -KILL -- "-$R4_PROC_GROUP" 2>/dev/null || true
wait "$R4_PROC_GROUP_LAUNCHER" 2>/dev/null || true
if [[ "$R4_PROC_STATUS" == "4" ]]; then
    pass "R4 V4 partial unreadable proc scan is UNKNOWN/status 4"
else
    fail "R4 V4 partial unreadable proc scan" "status=$R4_PROC_STATUS (expected 4)"
fi

# R4 negative: malformed inflight metadata fences every named non-action
# epoch/phase writer and action recovery.  No writer may rename state or move
# the epoch before returning status 4.
new_project r4_malformed_state_writer
make_loop "$PROJECT" 2026-08-09_00-00-03d
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
R4_BAD_STATE_STATUS=0
rlcr_state_update "$LOOP_DIR/state.md" "current_round=1" 2>/dev/null || R4_BAD_STATE_STATUS=$?
R4_BAD_STATE_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")

new_project r4_malformed_phase_writer
make_loop "$PROJECT" 2026-08-09_00-00-03e
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
R4_BAD_PHASE_STATUS=0
rlcr_phase_transition "$PROJECT/.humanize/rlcr" "$LOOP_DIR" \
    "$LOOP_DIR/state.md" "$LOOP_DIR/complete-state.md" 2>/dev/null || R4_BAD_PHASE_STATUS=$?
R4_BAD_PHASE_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")

new_project r4_malformed_methodology_writer
make_loop "$PROJECT" 2026-08-09_00-00-03f
mv "$LOOP_DIR/state.md" "$LOOP_DIR/methodology-analysis-state.md"
printf 'complete\n' > "$LOOP_DIR/.methodology-exit-reason"
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
R4_BAD_METH_STATUS=0
rlcr_methodology_complete_transition "$PROJECT/.humanize/rlcr" "$LOOP_DIR" \
    "$LOOP_DIR/methodology-analysis-state.md" "$LOOP_DIR/complete-state.md" \
    2>/dev/null || R4_BAD_METH_STATUS=$?
R4_BAD_METH_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")

new_project r4_malformed_recovery
make_loop "$PROJECT" 2026-08-09_00-00-03g
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
R4_BAD_ACTION_STATUS=0
rlcr_action_begin "$PROJECT/.humanize/rlcr" "$LOOP_DIR" impl 0 2>/dev/null || R4_BAD_ACTION_STATUS=$?
if [[ "$R4_BAD_STATE_STATUS" == "4" && "$R4_BAD_STATE_EPOCH" == "0" \
      && "$R4_BAD_PHASE_STATUS" == "4" && "$R4_BAD_PHASE_EPOCH" == "0" \
      && -f "$TEST_DIR/r4_malformed_phase_writer/project/.humanize/rlcr/2026-08-09_00-00-03e/state.md" \
      && "$R4_BAD_METH_STATUS" == "4" && "$R4_BAD_METH_EPOCH" == "0" \
      && -f "$TEST_DIR/r4_malformed_methodology_writer/project/.humanize/rlcr/2026-08-09_00-00-03f/methodology-analysis-state.md" \
      && "$R4_BAD_ACTION_STATUS" == "4" ]]; then
    pass "R4 damaged inflight makes state/phase/methodology/recovery fail closed with status 4"
else
    fail "R4 damaged inflight status-4 paths" \
        "state=$R4_BAD_STATE_STATUS/$R4_BAD_STATE_EPOCH phase=$R4_BAD_PHASE_STATUS/$R4_BAD_PHASE_EPOCH methodology=$R4_BAD_METH_STATUS/$R4_BAD_METH_EPOCH action=$R4_BAD_ACTION_STATUS"
fi

# The remaining direct non-action epoch writers use the same fence: cancel,
# methodology entry, and the PostToolUse session handshake.
new_project r4_malformed_cancel_writer
make_loop "$PROJECT" 2026-08-09_00-00-03j
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
R4_BAD_CANCEL_STATUS=0
rlcr_cancel_transaction "$PROJECT/.humanize/rlcr" "$LOOP_DIR" \
    "$PROJECT/.humanize/.pending-rlcr-cancel" 2>/dev/null || R4_BAD_CANCEL_STATUS=$?
R4_BAD_CANCEL_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")

new_project r4_malformed_methodology_entry
make_loop "$PROJECT" 2026-08-09_00-00-03k 0 0 false
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
run_hook "$PROJECT" "$TEST_DIR/r4-methodology-entry.json" || true
R4_BAD_METH_ENTRY_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")

new_project r4_malformed_posttool_writer
make_loop "$PROJECT" 2026-08-09_00-00-03l
printf 'corrupt\n' > "$LOOP_DIR/.action-inflight"
printf '%s\n%s\n' "$LOOP_DIR/state.md" "$SETUP_SCRIPT" \
    > "$PROJECT/.humanize/.pending-session-id"
R4_POST_JSON=$(jq -n --arg cmd "$SETUP_SCRIPT plan.md" --arg cwd "$PROJECT" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd,session_id:"r4-post-session"}')
R4_BAD_POST_STATUS=0
printf '%s' "$R4_POST_JSON" | CLAUDE_PROJECT_DIR="$PROJECT" "$POST_HOOK" \
    >/dev/null 2>&1 || R4_BAD_POST_STATUS=$?
R4_BAD_POST_EPOCH=$(rlcr_epoch_read "$LOOP_DIR")
R4_BAD_POST_SESSION=$(sed -n 's/^session_id:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ "$R4_BAD_CANCEL_STATUS" == "4" && "$R4_BAD_CANCEL_EPOCH" == "0" \
      && -f "$TEST_DIR/r4_malformed_cancel_writer/project/.humanize/rlcr/2026-08-09_00-00-03j/state.md" \
      && "$R4_BAD_METH_ENTRY_EPOCH" == "0" \
      && -f "$TEST_DIR/r4_malformed_methodology_entry/project/.humanize/rlcr/2026-08-09_00-00-03k/state.md" \
      && ! -e "$TEST_DIR/r4_malformed_methodology_entry/project/.humanize/rlcr/2026-08-09_00-00-03k/methodology-analysis-state.md" \
      && "$R4_BAD_POST_STATUS" == "4" && "$R4_BAD_POST_EPOCH" == "0" \
      && -z "$R4_BAD_POST_SESSION" ]]; then
    pass "R4 cancel/methodology-entry/PostToolUse epoch writers share the status-4 fence"
else
    fail "R4 remaining epoch-writer fences" \
        "cancel=$R4_BAD_CANCEL_STATUS/$R4_BAD_CANCEL_EPOCH methodology_entry=$R4_BAD_METH_ENTRY_EPOCH post=$R4_BAD_POST_STATUS/$R4_BAD_POST_EPOCH/$R4_BAD_POST_SESSION"
fi

# R4 negative: missing setsid cannot invoke even the Codex stub.  Export a
# narrow command wrapper to hide only `command -v setsid` from the real hook.
new_project r4_missing_setsid
make_loop "$PROJECT" 2026-08-09_00-00-03h
export CODEX_CALL_LOG="$TEST_DIR/r4-missing-setsid-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/r4-missing-setsid-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
(
    command() {
        if [[ "${1:-}" == "-v" && "${2:-}" == "setsid" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    export -f command
    run_hook "$PROJECT" "$TEST_DIR/r4-missing-setsid.json"
) || true
R4_NO_SETSID_CALLS=$(grep -c '^[a-z]' "$CODEX_CALL_LOG" 2>/dev/null || true)
if [[ "$R4_NO_SETSID_CALLS" == "0" \
      && $(jq -r '.decision // empty' "$TEST_DIR/r4-missing-setsid.json" 2>/dev/null) == "block" \
      && -f "$LOOP_DIR/state.md" ]]; then
    pass "R4 missing setsid fails closed before Codex payload launch"
else
    fail "R4 missing setsid negative path" \
        "calls=$R4_NO_SETSID_CALLS output=$(cat "$TEST_DIR/r4-missing-setsid.json" 2>/dev/null) err=$(tail -5 "$TEST_DIR/r4-missing-setsid.json.err" 2>/dev/null)"
fi

# R4 negative: a setsid implementation that does not establish pid=pgid=sid
# makes identity registration fail.  The unpublished gate must keep Codex at
# zero calls; the hook may emit a blocking decision or retain inflight fenced.
new_project r4_identity_registration
make_loop "$PROJECT" 2026-08-09_00-00-03i
R4_BAD_SETSID_BIN="$TEST_DIR/r4-bad-setsid-bin"
mkdir -p "$R4_BAD_SETSID_BIN"
cat > "$R4_BAD_SETSID_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$R4_BAD_SETSID_BIN/setsid"
export CODEX_CALL_LOG="$TEST_DIR/r4-identity-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/r4-identity-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
PATH="$R4_BAD_SETSID_BIN:$PATH" run_hook "$PROJECT" "$TEST_DIR/r4-identity.json" \
    RLCR_REVIEWER_GATE_WAIT_SECONDS=0 || true
R4_IDENTITY_CALLS=$(grep -c '^[a-z]' "$CODEX_CALL_LOG" 2>/dev/null || true)
R4_IDENTITY_DECISION=$(jq -r '.decision // empty' "$TEST_DIR/r4-identity.json" 2>/dev/null || true)
if [[ "$R4_IDENTITY_CALLS" == "0" \
      && ( "$R4_IDENTITY_DECISION" == "block" || -f "$LOOP_DIR/.action-inflight" ) ]]; then
    pass "R4 failed reviewer identity registration keeps payload behind unpublished gate"
else
    fail "R4 identity-registration negative path" \
        "calls=$R4_IDENTITY_CALLS decision=$R4_IDENTITY_DECISION inflight=$([[ -f "$LOOP_DIR/.action-inflight" ]] && echo yes || echo no) err=$(tail -5 "$TEST_DIR/r4-identity.json.err" 2>/dev/null)"
fi

# AC-4 / F-4: kill after commit and before stdout; replay without another round.
new_project ac4
make_loop "$PROJECT" 2026-08-09_00-00-04
export CODEX_CALL_LOG="$TEST_DIR/ac4-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac4-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_STUB_SLEEP=0
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac4-killed.json" \
    RLCR_TEST_KILL_AFTER_ACTION_COMMIT=1 RLCR_LOCK_LEASE_SECONDS=0 || true
sleep 1
ROUND_AFTER_KILL=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
run_hook "$PROJECT" "$TEST_DIR/ac4-replay.json" RLCR_LOCK_LEASE_SECONDS=0 || true
AC4_EXEC_COUNT=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
ROUND_AFTER_REPLAY=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ ! -s "$TEST_DIR/ac4-killed.json" && -s "$TEST_DIR/ac4-replay.json" \
      && "$AC4_EXEC_COUNT" == "1" && "$ROUND_AFTER_KILL" == "1" && "$ROUND_AFTER_REPLAY" == "1" ]]; then
    pass "AC-4 F-4 committed action replays after SIGKILL without second round"
else
    fail "AC-4 F-4 outbox recovery" "exec=$AC4_EXEC_COUNT rounds=$ROUND_AFTER_KILL/$ROUND_AFTER_REPLAY killed_bytes=$(wc -c < "$TEST_DIR/ac4-killed.json")"
fi

# The same recovery must work after a phase action makes the loop terminal;
# normal active-loop discovery can no longer find stop-state.md in that case.
new_project ac4_terminal
make_loop "$PROJECT" 2026-08-09_00-00-04b
rlcr_state_update "$LOOP_DIR/state.md" \
    "mainline_stall_count=10" "last_mainline_verdict=stalled"
export CODEX_CALL_LOG="$TEST_DIR/ac4-terminal-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac4-terminal-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_EXEC_OUTPUT="Mainline Progress Verdict: REGRESSED"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac4-terminal-killed.json" \
    RLCR_TEST_KILL_AFTER_ACTION_COMMIT=1 RLCR_LOCK_LEASE_SECONDS=0 || true
sleep 1
run_hook "$PROJECT" "$TEST_DIR/ac4-terminal-replay.json" RLCR_LOCK_LEASE_SECONDS=0 || true
AC4_TERMINAL_EXEC=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
if [[ ! -s "$TEST_DIR/ac4-terminal-killed.json" \
      && -s "$TEST_DIR/ac4-terminal-replay.json" \
      && "$AC4_TERMINAL_EXEC" == "1" && -f "$LOOP_DIR/stop-state.md" ]]; then
    pass "AC-4 terminal phase action replays after commit-before-output SIGKILL"
else
    fail "AC-4 terminal outbox discovery" \
        "exec=$AC4_TERMINAL_EXEC states=$(find "$LOOP_DIR" -maxdepth 1 -name '*state.md' -print)"
fi
export CODEX_EXEC_OUTPUT="Mainline Progress Verdict: ADVANCED"

# AC-4b / criterion 5: deterministic recovery at all five protocol fault
# points.  For every case the eventual action id is preserved and current_round
# advances at most once.  Sleeping below is only stale-lock lease expiry after
# SIGKILL; ack identity never consults elapsed time.

# F1: outbox committed, successor state not committed yet.
new_project ac4_f1_outbox
make_loop "$PROJECT" 2026-08-09_00-00-04c
export CODEX_CALL_LOG="$TEST_DIR/ac4-f1-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac4-f1-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac4-f1-killed.json" \
    RLCR_TEST_KILL_AFTER_OUTBOX_COMMIT=1 RLCR_LOCK_LEASE_SECONDS=0 || true
F1_ACTION=$(sed -n '1p' "$LOOP_DIR/.pending-action-id" 2>/dev/null || true)
F1_ROUND_BEFORE=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
sleep 1
run_hook "$PROJECT" "$TEST_DIR/ac4-f1-recovered.json" RLCR_LOCK_LEASE_SECONDS=0 || true
F1_FINAL_ACTION=$(jq -r '.action_id // empty' "$TEST_DIR/ac4-f1-recovered.json" 2>/dev/null || true)
F1_EXEC=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
F1_ROUND_AFTER=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ -n "$F1_ACTION" && "$F1_ACTION" == "$F1_FINAL_ACTION" \
   && "$F1_ROUND_BEFORE" == "0" && "$F1_ROUND_AFTER" == "1" \
   && "$F1_EXEC" == "2" ]]; then
    pass "criterion-5 F1 outbox fault recovers same action and one logical round"
else
    fail "criterion-5 F1 outbox recovery" \
        "action=$F1_ACTION/$F1_FINAL_ACTION round=$F1_ROUND_BEFORE/$F1_ROUND_AFTER exec=$F1_EXEC"
fi

# F2: successor state/phase commit completed, dispatch has not started.
new_project ac4_f2_state
make_loop "$PROJECT" 2026-08-09_00-00-04d
export CODEX_CALL_LOG="$TEST_DIR/ac4-f2-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac4-f2-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac4-f2-killed.json" \
    RLCR_TEST_KILL_AFTER_STATE_COMMIT=1 RLCR_LOCK_LEASE_SECONDS=0 || true
F2_ACTION=$(sed -n '1p' "$LOOP_DIR/.pending-action-id" 2>/dev/null || true)
F2_ROUND_BEFORE=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
sleep 1
run_hook "$PROJECT" "$TEST_DIR/ac4-f2-recovered.json" RLCR_LOCK_LEASE_SECONDS=0 || true
F2_FINAL_ACTION=$(jq -r '.action_id // empty' "$TEST_DIR/ac4-f2-recovered.json" 2>/dev/null || true)
F2_EXEC=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
F2_ROUND_AFTER=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ -n "$F2_ACTION" && "$F2_ACTION" == "$F2_FINAL_ACTION" \
   && "$F2_ROUND_BEFORE" == "1" && "$F2_ROUND_AFTER" == "1" \
   && "$F2_EXEC" == "1" ]]; then
    pass "criterion-5 F2 state fault replays action without second logical round"
else
    fail "criterion-5 F2 state recovery" \
        "action=$F2_ACTION/$F2_FINAL_ACTION round=$F2_ROUND_BEFORE/$F2_ROUND_AFTER exec=$F2_EXEC"
fi

# F3: stdout dispatch happened, delivered marker did not commit.  At-least-once
# permits the physical replay, but the logical transition and action id remain
# identical.
new_project ac4_f3_dispatch
make_loop "$PROJECT" 2026-08-09_00-00-04e
export CODEX_CALL_LOG="$TEST_DIR/ac4-f3-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac4-f3-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac4-f3-killed.json" \
    RLCR_TEST_KILL_AFTER_DISPATCH=1 RLCR_LOCK_LEASE_SECONDS=0 || true
F3_ACTION=$(jq -r '.action_id // empty' "$TEST_DIR/ac4-f3-killed.json" 2>/dev/null || true)
sleep 1
run_hook "$PROJECT" "$TEST_DIR/ac4-f3-recovered.json" RLCR_LOCK_LEASE_SECONDS=0 || true
F3_FINAL_ACTION=$(jq -r '.action_id // empty' "$TEST_DIR/ac4-f3-recovered.json" 2>/dev/null || true)
F3_EXEC=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
F3_ROUND=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ -n "$F3_ACTION" && "$F3_ACTION" == "$F3_FINAL_ACTION" \
   && "$F3_ROUND" == "1" && "$F3_EXEC" == "1" ]]; then
    pass "criterion-5 F3 dispatch fault physically replays one canonical action"
else
    fail "criterion-5 F3 dispatch recovery" \
        "action=$F3_ACTION/$F3_FINAL_ACTION round=$F3_ROUND exec=$F3_EXEC"
fi

# Prepare one delivered action for F4/F5 consumer-side recovery.
prepare_delivered_action() {
    local name="$1" sid="$2"
    new_project "$name"
    make_loop "$PROJECT" "$sid"
    export CODEX_CALL_LOG="$TEST_DIR/${name}-codex.log"
    export CODEX_LOCK_LOG="$TEST_DIR/${name}-lock.log"
    export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
    : > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
    run_hook "$PROJECT" "$TEST_DIR/${name}-delivered.json" || true
}

run_ack_recovery() {
    local kill_var="${1:-}"
    env STATE_LIB="$STATE_LIB" LOOP_SCOPE="$PROJECT/.humanize/rlcr" \
        LOOP_UNDER_TEST="$LOOP_DIR" "$kill_var"=1 RLCR_LOCK_LEASE_SECONDS=0 \
        bash -c 'source "$STATE_LIB"; rlcr_observe_successor "$LOOP_UNDER_TEST"; rlcr_action_recover_pending "$LOOP_SCOPE" "$LOOP_UNDER_TEST" "$RLCR_OBSERVED_GENERATION" "$RLCR_OBSERVED_PHASE"' \
        >/dev/null 2>&1 &
    local fault_pid=$!
    wait "$fault_pid" 2>/dev/null || true
}

finish_ack_recovery() {
    env STATE_LIB="$STATE_LIB" LOOP_SCOPE="$PROJECT/.humanize/rlcr" \
        LOOP_UNDER_TEST="$LOOP_DIR" RLCR_LOCK_LEASE_SECONDS=0 \
        bash -c 'source "$STATE_LIB"; rlcr_observe_successor "$LOOP_UNDER_TEST"; rlcr_action_recover_pending "$LOOP_SCOPE" "$LOOP_UNDER_TEST" "$RLCR_OBSERVED_GENERATION" "$RLCR_OBSERVED_PHASE"' \
        >/dev/null 2>&1 || true
}

# F4: consumer claim persisted, ack state not committed.
prepare_delivered_action ac4_f4_claim 2026-08-09_00-00-04f
F4_ACTION=$(sed -n '1p' "$LOOP_DIR/.pending-action-id")
F4_GEN=$(sed -n '1p' "$LOOP_DIR/.pending-successor-generation")
F4_PHASE=$(sed -n '1p' "$LOOP_DIR/.pending-successor-phase")
run_ack_recovery RLCR_TEST_KILL_AFTER_CONSUMER_CLAIM
F4_STATE_EPOCH=$(sed -n 's/^control_epoch:[[:space:]]*//p' "$LOOP_DIR/state.md")
F4_SIDECAR_EPOCH=$(sed -n '1p' "$LOOP_DIR/.control-epoch")
F4_STATE_PENDING=$(sed -n 's/^pending_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")
F4_STATE_ACK=$(sed -n 's/^ack_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ -f "$LOOP_DIR/.decision-claim" \
      && "$(rlcr_metadata_value "$LOOP_DIR/.decision-claim" action_id)" == "$F4_ACTION" \
      && "$(rlcr_metadata_value "$LOOP_DIR/.decision-claim" successor_generation)" == "$F4_GEN" \
      && "$(rlcr_metadata_value "$LOOP_DIR/.decision-claim" successor_phase)" == "$F4_PHASE" \
      && "$(sed -n '1p' "$LOOP_DIR/.pending-action-id")" == "$F4_ACTION" \
      && "$F4_STATE_PENDING" == "$F4_ACTION" && -z "$F4_STATE_ACK" \
      && "$F4_STATE_EPOCH" == "$F4_GEN" && "$F4_SIDECAR_EPOCH" == "$F4_GEN" \
      && -d "$PROJECT/.humanize/rlcr/.rlcr-control.lock" ]]; then
    pass "criterion-5 F4 fault reaches persisted claim before ack application"
else
    fail "criterion-5 F4 fault intermediate state" \
        "claim=$(cat "$LOOP_DIR/.decision-claim" 2>/dev/null) pending=$F4_STATE_PENDING/$F4_ACTION ack=$F4_STATE_ACK epoch=$F4_STATE_EPOCH/$F4_SIDECAR_EPOCH/$F4_GEN lock=$([[ -d "$PROJECT/.humanize/rlcr/.rlcr-control.lock" ]] && echo yes || echo no)"
fi
sleep 1
finish_ack_recovery
F4_ROUND=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
F4_FINAL_EPOCH=$(sed -n 's/^control_epoch:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ "$F4_ROUND" == "1" && ! -e "$LOOP_DIR/.pending-action-id" \
   && ! -e "$LOOP_DIR/.decision-claim" \
   && "$F4_FINAL_EPOCH" == "$((F4_GEN + 1))" \
   && "$(sed -n '1p' "$LOOP_DIR/.control-epoch")" == "$F4_FINAL_EPOCH" \
   && "$(sed -n 's/^ack_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F4_ACTION" \
   && "$(sed -n 's/^ack_successor_generation:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F4_GEN" \
   && "$(sed -n 's/^ack_successor_phase:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F4_PHASE" ]]; then
    pass "criterion-5 F4 consumer-claim fault recovers bound ack without another round"
else
    fail "criterion-5 F4 consumer-claim recovery" "round=$F4_ROUND state=$(tail -20 "$LOOP_DIR/state.md")"
fi

# F5: ack state committed, cleanup/epoch sidecar not completed.
prepare_delivered_action ac4_f5_ack 2026-08-09_00-00-04g
F5_ACTION=$(sed -n '1p' "$LOOP_DIR/.pending-action-id")
F5_GEN=$(sed -n '1p' "$LOOP_DIR/.pending-successor-generation")
F5_PHASE=$(sed -n '1p' "$LOOP_DIR/.pending-successor-phase")
run_ack_recovery RLCR_TEST_KILL_AFTER_ACK_COMMIT
F5_STATE_EPOCH=$(sed -n 's/^control_epoch:[[:space:]]*//p' "$LOOP_DIR/state.md")
F5_SIDECAR_EPOCH=$(sed -n '1p' "$LOOP_DIR/.control-epoch")
F5_STATE_PENDING=$(sed -n 's/^pending_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")
F5_STATE_ACK=$(sed -n 's/^ack_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ -f "$LOOP_DIR/.decision-claim" \
      && "$(rlcr_metadata_value "$LOOP_DIR/.decision-claim" action_id)" == "$F5_ACTION" \
      && "$(sed -n '1p' "$LOOP_DIR/.pending-action-id")" == "$F5_ACTION" \
      && -z "$F5_STATE_PENDING" && "$F5_STATE_ACK" == "$F5_ACTION" \
      && "$F5_STATE_EPOCH" == "$((F5_GEN + 1))" \
      && "$F5_SIDECAR_EPOCH" == "$F5_GEN" \
      && -d "$PROJECT/.humanize/rlcr/.rlcr-control.lock" ]]; then
    pass "criterion-5 F5 fault reaches ack commit before epoch/cleanup"
else
    fail "criterion-5 F5 fault intermediate state" \
        "claim=$(cat "$LOOP_DIR/.decision-claim" 2>/dev/null) pending=$F5_STATE_PENDING/$F5_ACTION ack=$F5_STATE_ACK epoch=$F5_STATE_EPOCH/$F5_SIDECAR_EPOCH expected=$((F5_GEN + 1))/$F5_GEN lock=$([[ -d "$PROJECT/.humanize/rlcr/.rlcr-control.lock" ]] && echo yes || echo no)"
fi
sleep 1
finish_ack_recovery
F5_ROUND=$(sed -n 's/^current_round:[[:space:]]*//p' "$LOOP_DIR/state.md")
if [[ "$F5_ROUND" == "1" && ! -e "$LOOP_DIR/.pending-action-id" \
   && ! -e "$LOOP_DIR/.decision-claim" \
   && "$(sed -n '1p' "$LOOP_DIR/.control-epoch")" == "$F5_STATE_EPOCH" \
   && "$(sed -n 's/^ack_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F5_ACTION" \
   && "$(sed -n 's/^ack_successor_generation:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F5_GEN" \
   && "$(sed -n 's/^ack_successor_phase:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$F5_PHASE" ]]; then
    pass "criterion-5 F5 ack-commit fault recovers cleanup without another round"
else
    fail "criterion-5 F5 ack recovery" "round=$F5_ROUND state=$(tail -20 "$LOOP_DIR/state.md")"
fi

# Criterion 6 negative proof: action_id alone, or action_id plus only one
# successor coordinate, cannot acknowledge.  The exact persisted tuple can.
prepare_delivered_action ac4_ack_binding 2026-08-09_00-00-04h
ACK_ID=$(sed -n '1p' "$LOOP_DIR/.pending-action-id")
ACK_GEN=$(sed -n '1p' "$LOOP_DIR/.pending-successor-generation")
ACK_PHASE=$(sed -n '1p' "$LOOP_DIR/.pending-successor-phase")
set +e
printf 'wrong-action-id\n' > "$LOOP_DIR/.decision-delivered"
rlcr_action_recover_pending "$PROJECT/.humanize/rlcr" "$LOOP_DIR" "$ACK_GEN" "$ACK_PHASE"
WRONG_ID_STATUS=$?
printf '%s\n' "$ACK_ID" > "$LOOP_DIR/.decision-delivered"
rlcr_action_recover_pending "$PROJECT/.humanize/rlcr" "$LOOP_DIR" "$((ACK_GEN + 1))" "$ACK_PHASE"
WRONG_GEN_STATUS=$?
rlcr_action_recover_pending "$PROJECT/.humanize/rlcr" "$LOOP_DIR" "$ACK_GEN" wrong-phase
WRONG_PHASE_STATUS=$?
set -e
PENDING_AFTER_WRONG=$(sed -n '1p' "$LOOP_DIR/.pending-action-id" 2>/dev/null || true)
rlcr_action_recover_pending "$PROJECT/.humanize/rlcr" "$LOOP_DIR" "$ACK_GEN" "$ACK_PHASE" || true
if [[ "$WRONG_ID_STATUS" == "2" && "$WRONG_GEN_STATUS" == "2" \
   && "$WRONG_PHASE_STATUS" == "2" \
   && "$PENDING_AFTER_WRONG" == "$ACK_ID" && ! -e "$LOOP_DIR/.pending-action-id" \
   && "$(sed -n 's/^ack_action_id:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "$ACK_ID" ]]; then
    pass "criterion-6 ack requires action_id plus exact successor generation/phase"
else
    fail "criterion-6 successor-bound ack" \
        "statuses=$WRONG_ID_STATUS/$WRONG_GEN_STATUS/$WRONG_PHASE_STATUS pending=$PENDING_AFTER_WRONG/$ACK_ID"
fi

# AC-5 / F-6: global cancel searches past a newer terminal session.
new_project ac5
make_loop "$PROJECT" 2026-08-09_00-00-01
ACTIVE_OLDER="$LOOP_DIR"
mkdir -p "$PROJECT/.humanize/rlcr/2026-08-09_00-00-59"
printf '%s\n' terminal > "$PROJECT/.humanize/rlcr/2026-08-09_00-00-59/complete-state.md"
if (cd "$PROJECT" && CLAUDE_PROJECT_DIR="$PROJECT" "$CANCEL_LOOP" >/dev/null 2>&1) \
   && [[ -f "$ACTIVE_OLDER/cancel-state.md" ]]; then
    pass "AC-5 F-6 multi-session global cancel finds the running loop"
else
    fail "AC-5 F-6 multi-session cancel" "active older loop was not canceled"
fi

# AC-6 / F-7: methodology entry recovers after a killed sidecar writer.
new_project ac6
make_loop "$PROJECT" 2026-08-09_00-00-06 0 0 false
run_hook "$PROJECT" "$TEST_DIR/ac6-killed.json" \
    RLCR_TEST_KILL_METHODOLOGY_AFTER_SIDECARS=1 RLCR_LOCK_LEASE_SECONDS=0 || true
sleep 1
run_hook "$PROJECT" "$TEST_DIR/ac6-recovered.json" RLCR_LOCK_LEASE_SECONDS=0 || true
if [[ -f "$LOOP_DIR/methodology-analysis-state.md" \
      && -f "$LOOP_DIR/.methodology-exit-reason" \
      && ! -d "$PROJECT/.humanize/rlcr/.rlcr-control.lock" ]]; then
    pass "AC-6 F-7 methodology entry recovers after SIGKILL"
else
    fail "AC-6 F-7 methodology recovery" "files: $(find "$LOOP_DIR" -maxdepth 1 -print | sort)"
fi

# AC-7 / F-8: a missing current_round is inserted, not silently ignored.
AC7="$TEST_DIR/ac7/rlcr/session"
mkdir -p "$AC7"
cat > "$AC7/state.md" <<'EOF'
---
max_iterations: 5
review_started: true
base_branch: main
---
EOF
if rlcr_state_update "$AC7/state.md" "current_round=7" \
   && grep -q '^current_round: 7$' "$AC7/state.md"; then
    pass "AC-7 F-8 structured round advance inserts missing current_round"
else
    fail "AC-7 F-8 missing-field round advance" "$(cat "$AC7/state.md")"
fi

# AC-8: stale mkdir lease is taken over after SIGKILL.
AC8_SCOPE="$TEST_DIR/ac8/rlcr"
mkdir -p "$AC8_SCOPE"
(source "$STATE_LIB"; RLCR_LOCK_LEASE_SECONDS=0; rlcr_lock_acquire "$AC8_SCOPE"; \
    printf 'ready\n' > "$TEST_DIR/ac8-ready"; while :; do sleep 1; done) & AC8_PID=$!
while [[ ! -f "$TEST_DIR/ac8-ready" ]]; do sleep 0.01; done
kill -9 "$AC8_PID" 2>/dev/null || true
wait "$AC8_PID" 2>/dev/null || true
sleep 1
if (source "$STATE_LIB"; RLCR_LOCK_LEASE_SECONDS=0; rlcr_lock_acquire "$AC8_SCOPE" 5; rlcr_lock_release); then
    pass "AC-8 stale lease recovers after SIGKILL"
else
    fail "AC-8 stale lease recovery" "replacement writer could not acquire"
fi

# AC-9: the real hook's stubbed Codex call observes no lock; sampled hold ratio <5%.
new_project ac9
make_loop "$PROJECT" 2026-08-09_00-00-09
export CODEX_CALL_LOG="$TEST_DIR/ac9-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac9-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_STUB_SLEEP=5
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
(run_hook "$PROJECT" "$TEST_DIR/ac9.json") & AC9_PID=$!
TOTAL_SAMPLES=0; LOCKED_SAMPLES=0
while kill -0 "$AC9_PID" 2>/dev/null; do
    TOTAL_SAMPLES=$((TOTAL_SAMPLES + 1))
    [[ ! -d "$CODEX_LOCK_SCOPE/.rlcr-control.lock" ]] || LOCKED_SAMPLES=$((LOCKED_SAMPLES + 1))
    sleep 0.01
done
wait "$AC9_PID" || true
AC9_RATIO=$(awk -v locked="$LOCKED_SAMPLES" -v total="$TOTAL_SAMPLES" \
    'BEGIN { if (total == 0) print 100; else printf "%.2f", (locked * 100 / total) }')
AC9_EXEC_COUNT=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
if [[ "$AC9_EXEC_COUNT" == "1" && ! -s "$CODEX_LOCK_LOG" ]] \
   && awk -v ratio="$AC9_RATIO" 'BEGIN { exit !(ratio < 5.0) }'; then
    pass "AC-9 Codex runs outside lock; sampled hold ratio ${AC9_RATIO}%"
else
    fail "AC-9 short lock scope" "exec=$AC9_EXEC_COUNT lock_log=$(cat "$CODEX_LOCK_LOG") ratio=${AC9_RATIO}%"
fi

# AC-10: setup handshake and finalize/methodology use the real scripts too.
new_project ac10_setup
export CODEX_CALL_LOG="$TEST_DIR/ac10-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac10-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
if (cd "$PROJECT" && CLAUDE_PROJECT_DIR="$PROJECT" "$SETUP_SCRIPT" plan.md --track-plan-file --max 2 \
    --benchmark-command "$BENCHMARK_COMMAND" --benchmark-timeout "$BENCHMARK_TIMEOUT" >/dev/null 2>&1); then
    SETUP_LOOP=$(find "$PROJECT/.humanize/rlcr" -mindepth 1 -maxdepth 1 -type d ! -name '.rlcr-control.lock' | head -1)
    SETUP_JSON=$(jq -n --arg cmd "$SETUP_SCRIPT plan.md --track-plan-file --max 2" --arg cwd "$PROJECT" \
        '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd,session_id:"ac10-session"}')
    printf '%s' "$SETUP_JSON" | CLAUDE_PROJECT_DIR="$PROJECT" "$POST_HOOK"
    if grep -q '^session_id: ac10-session$' "$SETUP_LOOP/state.md" \
       && "$CANCEL_SESSION" --project "$PROJECT" --session-id "$(basename "$SETUP_LOOP")" >/dev/null; then
        pass "AC-10 real setup handshake and session cancel"
    else
        fail "AC-10 setup/PostToolUse/session cancel" "setup handshake did not commit"
    fi
else
    fail "AC-10 real setup script" "setup-rlcr-loop.sh failed"
fi

new_project ac10_finalize
make_loop "$PROJECT" 2026-08-09_00-00-10 0 5 false
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalize-state.md"
printf '# Finalize Summary\nAll checks complete.\n' > "$LOOP_DIR/finalize-summary.md"
run_hook "$PROJECT" "$TEST_DIR/ac10-methodology.json" || true
AC10_METHODOLOGY_ENTERED=false
if [[ -f "$LOOP_DIR/methodology-analysis-state.md" \
      && ! -f "$LOOP_DIR/complete-state.md" ]]; then
    AC10_METHODOLOGY_ENTERED=true
fi
printf '# Methodology Report\nEvidence-backed report.\n' > "$LOOP_DIR/methodology-analysis-report.md"
printf 'analysis complete\n' > "$LOOP_DIR/methodology-analysis-done.md"
run_hook "$PROJECT" "$TEST_DIR/ac10-complete.json" || true
if [[ "$AC10_METHODOLOGY_ENTERED" == "true" \
      && -f "$LOOP_DIR/complete-state.md" \
      && ! -f "$LOOP_DIR/methodology-analysis-state.md" ]]; then
    pass "AC-10 real finalize/methodology terminal flow"
else
    fail "AC-10 finalize/methodology flow" "files: $(find "$LOOP_DIR" -maxdepth 1 -name '*state.md' -print)"
fi

# F-9: COMPLETE may transition to review-ready, but must not run codex review
# in the same hook process.
new_project ac10_f9
make_loop "$PROJECT" 2026-08-09_00-00-11 0 5 true
export CODEX_CALL_LOG="$TEST_DIR/ac10-f9-codex.log"
export CODEX_LOCK_LOG="$TEST_DIR/ac10-f9-lock.log"
export CODEX_LOCK_SCOPE="$PROJECT/.humanize/rlcr"
export CODEX_STUB_SLEEP=0
export CODEX_EXEC_OUTPUT=$'Mainline Progress Verdict: ADVANCED\n\nCOMPLETE'
export CODEX_EXEC_SUFFIX=""
: > "$CODEX_CALL_LOG"; : > "$CODEX_LOCK_LOG"
run_hook "$PROJECT" "$TEST_DIR/ac10-f9.json" || true
F9_EXEC=$(grep -c '^exec$' "$CODEX_CALL_LOG" 2>/dev/null || true)
F9_REVIEW=$(grep -c '^review$' "$CODEX_CALL_LOG" 2>/dev/null || true)
if [[ "$F9_EXEC" == "1" && "$F9_REVIEW" == "0" \
      && -f "$LOOP_DIR/.review-phase-started" \
      && "$(sed -n 's/^review_started:[[:space:]]*//p' "$LOOP_DIR/state.md")" == "true" ]]; then
    pass "F-9 one hook process consumes at most one Codex timeout budget"
else
    fail "F-9 single-Codex hook budget" \
        "exec=$F9_EXEC review=$F9_REVIEW marker=$([[ -f "$LOOP_DIR/.review-phase-started" ]] && echo yes || echo no) review_started=$(sed -n 's/^review_started:[[:space:]]*//p' "$LOOP_DIR/state.md") output=$(cat "$TEST_DIR/ac10-f9.json") stderr=$(tail -5 "$TEST_DIR/ac10-f9.json.err")"
fi

# F-10/F-11: PostToolUse uses only the leaf writer, and the real validator
# denies model-shell state renames even when the historical signal exists.
if grep -q 'loop-state-write.sh' "$POST_HOOK" && ! grep -q 'loop-common.sh' "$POST_HOOK"; then
    pass "F-10 PostToolUse sources the zero-dependency leaf module only"
else
    fail "F-10 leaf-module boundary" "PostToolUse dependency boundary regressed"
fi

new_project ac10_f11
make_loop "$PROJECT" 2026-08-09_00-00-12
printf 'legacy-signal\n' > "$LOOP_DIR/.cancel-requested"
VALIDATOR_JSON=$(jq -n --arg cmd "mv $LOOP_DIR/state.md $LOOP_DIR/cancel-state.md" \
    '{tool_name:"Bash",tool_input:{command:$cmd}}')
set +e
VALIDATOR_OUTPUT=$(cd "$PROJECT" && printf '%s' "$VALIDATOR_JSON" | \
    CLAUDE_PROJECT_DIR="$PROJECT" "$PLUGIN_ROOT/hooks/loop-bash-validator.sh" 2>&1)
VALIDATOR_STATUS=$?
set -e
if [[ "$VALIDATOR_STATUS" == "2" ]] && grep -q 'cancel-rlcr-loop' <<< "$VALIDATOR_OUTPUT"; then
    pass "F-11 validator denies direct mv and redirects to cancel script"
else
    fail "F-11 validator cancel whitelist removal" "status=$VALIDATOR_STATUS output=$VALIDATOR_OUTPUT"
fi

# AC-10 aggregate explicitly covers both cancel CLIs, post, setup, finalize,
# methodology, gate, and native Stop through the assertions above.
if [[ -f "$ACTIVE_OLDER/cancel-state.md" && -s "$TEST_DIR/ac3-native.json" \
      && -s "$TEST_DIR/ac3-gate.json" ]]; then
    pass "AC-10 end-to-end real-script coverage matrix complete"
else
    fail "AC-10 real-script coverage matrix" "one or more entry points lacked evidence"
fi

echo
printf 'W4a.5 acceptance: %d passed, %d failed, 0 skipped\n' "$PASSED" "$FAILED"
printf 'Passed: %d\nFailed: %d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
