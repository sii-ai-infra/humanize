#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

git -C "$TMP_ROOT" init -q
git -C "$TMP_ROOT" config user.email test@example.com
git -C "$TMP_ROOT" config user.name test
printf 'fixture\n' >"$TMP_ROOT/fixture"
git -C "$TMP_ROOT" add fixture
git -C "$TMP_ROOT" commit -qm fixture

LOOP_DIR="$TMP_ROOT/.humanize/rlcr/test"
mkdir -p "$LOOP_DIR"
printf '%s' 'printf "%s" "$KERNAUT_RLCR_ROUND" > gate-round-env.txt; echo benchmark-failed; exit 7' >"$LOOP_DIR/benchmark-command.sh"

"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 0 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 10

grep -Fq 'Status: **failed**' "$LOOP_DIR/round-0-benchmark.md"
grep -Fq 'Exit code: **7**' "$LOOP_DIR/round-0-benchmark.md"
grep -q 'benchmark-failed' "$LOOP_DIR/round-0-benchmark.log"
# The gate exports the round so generated benchmark.py can attribute rows.
[[ "$(cat "$TMP_ROOT/gate-round-env.txt" 2>/dev/null)" == "0" ]]

# The cumulative rounds report is appended best-effort after the benchmark.
# Its helper lives in the KOP scaffold; when present, one Round 0 section is
# written under docs/rounds-report.md.
if [[ -f "$TMP_ROOT/docs/rounds-report.md" ]]; then
    grep -q '^## Round 0 —' "$TMP_ROOT/docs/rounds-report.md"
    grep -Fq 'Status: **failed**' "$TMP_ROOT/docs/rounds-report.md"
    grep -Fq 'no rows recorded for this round' "$TMP_ROOT/docs/rounds-report.md"
fi

# Repeated Stop events must consume the existing result, not rerun the command.
printf '%s' 'echo should-not-run; exit 0' >"$LOOP_DIR/benchmark-command.sh"
"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 0 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 10
! grep -q 'should-not-run' "$LOOP_DIR/round-0-benchmark.log"
# The idempotency receipt also keeps the report single-section.
if [[ -f "$TMP_ROOT/docs/rounds-report.md" ]]; then
    [[ "$(grep -c '^## Round 0 —' "$TMP_ROOT/docs/rounds-report.md")" == 1 ]]
fi

printf '%s' 'sleep 5' >"$LOOP_DIR/benchmark-command.sh"
"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 1 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 1
grep -Fq 'Status: **timeout**' "$LOOP_DIR/round-1-benchmark.md"
grep -Fq 'Exit code: **124**' "$LOOP_DIR/round-1-benchmark.md"

echo "round benchmark tests passed"
