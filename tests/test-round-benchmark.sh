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
printf '%s' 'echo benchmark-failed; exit 7' >"$LOOP_DIR/benchmark-command.sh"

"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 0 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 10

grep -Fq 'Status: **failed**' "$LOOP_DIR/round-0-benchmark.md"
grep -Fq 'Exit code: **7**' "$LOOP_DIR/round-0-benchmark.md"
grep -q 'benchmark-failed' "$LOOP_DIR/round-0-benchmark.log"

# Repeated Stop events must consume the existing result, not rerun the command.
printf '%s' 'echo should-not-run; exit 0' >"$LOOP_DIR/benchmark-command.sh"
"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 0 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 10
! grep -q 'should-not-run' "$LOOP_DIR/round-0-benchmark.log"

printf '%s' 'sleep 5' >"$LOOP_DIR/benchmark-command.sh"
"$ROOT/scripts/run-round-benchmark.sh" \
    --project-root "$TMP_ROOT" --loop-dir "$LOOP_DIR" --round 1 \
    --command-file "$LOOP_DIR/benchmark-command.sh" --timeout 1
grep -Fq 'Status: **timeout**' "$LOOP_DIR/round-1-benchmark.md"
grep -Fq 'Exit code: **124**' "$LOOP_DIR/round-1-benchmark.md"

echo "round benchmark tests passed"
