#!/usr/bin/env bash
# Run one Codex reviewer behind a parent-published start gate.  The Stop hook
# launches this script as a new session/process-group leader, persists that
# identity, and only then publishes the gate.  Until the gate is published this
# worker cannot invoke Codex or touch the project working tree.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# GNU timeout normally places its payload in another process group.  That is
# exactly the orphan window this worker must eliminate, so reviewer payloads
# use --foreground and remain in the already-persisted worker session/group.
run_reviewer_with_timeout() {
    local timeout_value="$1"
    shift
    case "$TIMEOUT_IMPL" in
        timeout|gtimeout)
            "$TIMEOUT_IMPL" --foreground "$timeout_value" "$@"
            ;;
        *)
            # Python subprocesses inherit this worker's process group.  The
            # no-timeout fallback does too.
            run_with_timeout "$timeout_value" "$@"
            ;;
    esac
}

gate_file=""
worker_id=""
result_file=""
stdin_file=""
working_dir=""
timeout_seconds=""
stdout_file=""
stderr_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gate) gate_file="${2:-}"; shift 2 ;;
        --worker-id) worker_id="${2:-}"; shift 2 ;;
        --result) result_file="${2:-}"; shift 2 ;;
        --stdin) stdin_file="${2:-}"; shift 2 ;;
        --cwd) working_dir="${2:-}"; shift 2 ;;
        --timeout) timeout_seconds="${2:-}"; shift 2 ;;
        --stdout) stdout_file="${2:-}"; shift 2 ;;
        --stderr) stderr_file="${2:-}"; shift 2 ;;
        --) shift; break ;;
        *) echo "Error: unknown reviewer-worker option: $1" >&2; exit 125 ;;
    esac
done

if [[ -z "$gate_file" || -z "$worker_id" || -z "$result_file" \
   || -z "$stdin_file" || -z "$working_dir" || -z "$timeout_seconds" \
   || -z "$stdout_file" || -z "$stderr_file" || $# -eq 0 \
   || ! "$worker_id" =~ ^[A-Za-z0-9_.-]+$ \
   || ! "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    echo "Error: incomplete reviewer-worker invocation" >&2
    exit 125
fi

# A worker orphaned before identity registration is harmless: it has no gate,
# exits after a bounded wait, and never invokes the payload.
gate_wait_seconds="${RLCR_REVIEWER_GATE_WAIT_SECONDS:-30}"
[[ "$gate_wait_seconds" =~ ^[0-9]+$ ]] || gate_wait_seconds=30
gate_deadline=$(( $(date +%s) + gate_wait_seconds ))
while :; do
    if [[ -f "$gate_file" ]]; then
        IFS= read -r observed_worker_id < "$gate_file" || true
        [[ "$observed_worker_id" == "$worker_id" ]] || exit 125
        break
    fi
    [[ $(date +%s) -lt "$gate_deadline" ]] || exit 125
    sleep 0.01
done

status=0
if [[ "$stdout_file" == "$stderr_file" ]]; then
    (
        cd "$working_dir" || exit 125
        run_reviewer_with_timeout "$timeout_seconds" "$@" < "$stdin_file"
    ) > "$stdout_file" 2>&1 || status=$?
else
    (
        cd "$working_dir" || exit 125
        run_reviewer_with_timeout "$timeout_seconds" "$@" < "$stdin_file"
    ) > "$stdout_file" 2> "$stderr_file" || status=$?
fi

result_temp="${result_file}.tmp.$$"
printf '%s\n' "$status" > "$result_temp"
mv "$result_temp" "$result_file"
exit "$status"
