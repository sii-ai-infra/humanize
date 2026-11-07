#!/bin/bash
# Runs only on a private copy made by the fixed Python helper. No live loop
# path is accepted here. Native Humanize alone calculates its next/maxiter.
set -euo pipefail
umask 077
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PLUGIN_ROOT/hooks/lib/loop-common.sh"
LOOP_DIR="$1"
STATE_FILE="$LOOP_DIR/$2"
EXPECTED_ROUND="$3"
RECEIPT_FILE="$4"
RAW_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
for field in "$FIELD_CURRENT_ROUND" "$FIELD_MAX_ITERATIONS"; do
    raw=$(printf '%s\n' "$RAW_FRONTMATTER" | grep "^${field}:" || true)
    # Exactly one canonical field; do not accept defaults, arithmetic
    # expressions, octal-looking values or whitespace hidden by native tr.
    [[ "$raw" =~ ^${field}:\ (0|[1-9][0-9]{0,17})$ ]] || exit 2
done
parse_state_file "$STATE_FILE"
CURRENT_ROUND="$STATE_CURRENT_ROUND"
MAX_ITERATIONS="$STATE_MAX_ITERATIONS"
[[ "$MAX_ITERATIONS" =~ ^(0|[1-9][0-9]{0,17})$ ]] || exit 2
[[ "$CURRENT_ROUND" == "$EXPECTED_ROUND" ]] || exit 2
reason=$(jq -r .reason < "$RECEIPT_FILE")

# This is the original managed-completion repair body, on private files.
# Keep stdout and flag differences between the two branches intentional.
next=$((CURRENT_ROUND + 1))
if [[ $next -gt $MAX_ITERATIONS ]]; then
    mv "$STATE_FILE" "$LOOP_DIR/maxiter-state.md"
    rm -f "$LOOP_DIR/.methodology-exit-reason"
    printf '%s\n' "$reason" > "$LOOP_DIR/round-${CURRENT_ROUND}-completion-blocked.md"
    exit 0
fi
if [[ "$STATE_FILE" != "$LOOP_DIR/state.md" ]]; then
    mv "$STATE_FILE" "$LOOP_DIR/state.md"
fi
STATE_FILE="$LOOP_DIR/state.md"
upsert_state_fields "$STATE_FILE" \
    "${FIELD_CURRENT_ROUND}=$next" "${FIELD_REVIEW_STARTED}=false" \
    "${FIELD_MAINLINE_STALL_COUNT}=0" "${FIELD_DRIFT_STATUS}=${DRIFT_STATUS_NORMAL}"
rm -f "$LOOP_DIR/.review-phase-started" "$LOOP_DIR/.methodology-exit-reason"
printf '# Required completion corrections\n\n%s\n\nContinue within the approved contract and remaining iteration budget. Keep benchmark definitions frozen. Use the fixed amendment workflow for allowed reference/input compatibility repairs; ask a real question only for a business decision.\n' "$reason" > "$LOOP_DIR/round-${next}-prompt.md"
jq -n --arg reason "$reason" --argjson round "$next" '{decision:"block",reason:$reason,systemMessage:"Completion validation requires implementation corrections",repair_round:$round}'
