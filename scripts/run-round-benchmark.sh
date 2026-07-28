#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: run-round-benchmark.sh --project-root DIR --loop-dir DIR --round N --command-file FILE --timeout SECONDS" >&2
}

PROJECT_ROOT=""
LOOP_DIR=""
ROUND=""
COMMAND_FILE=""
TIMEOUT_SECONDS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-root) PROJECT_ROOT="${2:-}"; shift 2 ;;
        --loop-dir) LOOP_DIR="${2:-}"; shift 2 ;;
        --round) ROUND="${2:-}"; shift 2 ;;
        --command-file) COMMAND_FILE="${2:-}"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done

if [[ -z "$PROJECT_ROOT" || -z "$LOOP_DIR" || ! "$ROUND" =~ ^[0-9]+$ ]] || \
   [[ ! -f "$COMMAND_FILE" || ! "$TIMEOUT_SECONDS" =~ ^[0-9]+$ || "$TIMEOUT_SECONDS" -lt 1 ]]; then
    usage
    exit 2
fi

LOG_FILE="$LOOP_DIR/round-${ROUND}-benchmark.log"
RESULT_FILE="$LOOP_DIR/round-${ROUND}-benchmark.md"
COMMAND=$(cat "$COMMAND_FILE")
HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A result file is the idempotency receipt. Repeated Stop events for the same
# round must review the original full benchmark rather than rerun it.
if [[ -f "$RESULT_FILE" ]]; then
    exit 0
fi

set +e
(
    cd "$PROJECT_ROOT"
    bash -lc "$COMMAND"
) >"$LOG_FILE" 2>&1 &
BENCHMARK_PID=$!

TIMED_OUT=false
ELAPSED=0
while kill -0 "$BENCHMARK_PID" 2>/dev/null; do
    if [[ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]]; then
        TIMED_OUT=true
        kill -TERM "$BENCHMARK_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$BENCHMARK_PID" 2>/dev/null || true
        break
    fi
    sleep 1
    ELAPSED=$((ELAPSED + 1))
done
wait "$BENCHMARK_PID"
EXIT_CODE=$?
set -e

if [[ "$TIMED_OUT" == "true" ]]; then
    STATUS="timeout"
    EXIT_CODE=124
elif [[ "$EXIT_CODE" -eq 0 ]]; then
    STATUS="passed"
else
    STATUS="failed"
fi

FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat >"$RESULT_FILE" <<EOF
# Round $ROUND Full Benchmark

- Command: \`$COMMAND\`
- Git HEAD: \`$HEAD_SHA\`
- Started: $STARTED_AT
- Finished: $FINISHED_AT
- Timeout seconds: $TIMEOUT_SECONDS
- Status: **$STATUS**
- Exit code: **$EXIT_CODE**
- Full log: \`$(basename "$LOG_FILE")\`
EOF

# Benchmark failure is evidence, not a gate runtime failure. The reviewer must
# receive and assess it, so this helper succeeds once the record is durable.
exit 0
