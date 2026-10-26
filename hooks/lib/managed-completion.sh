# Completion authority is delegated only for explicitly managed bundles. The
# controller retains every lifecycle transition; the broker cannot rename state.
managed_completion_validation() {
    [[ "${HUMANIZE_MANAGED_RELIABILITY_V1:-}" == "1" ]] || return 0
    local result verdict reason next
    if [[ -z "${HUMANIZE_COMPLETION_VALIDATOR:-}" || ! -x "$HUMANIZE_COMPLETION_VALIDATOR" ]]; then
        jq -n '{decision:"block",reason:"The managed completion validator is unavailable. Keep the current lifecycle and request platform recovery; do not declare completion.",systemMessage:"Completion validation is unavailable",platform_blocked:true}'
        return 1
    fi
    if ! result=$("$HUMANIZE_COMPLETION_VALIDATOR"); then
        jq -n '{decision:"block",reason:"Completion validation did not return a verified result. Its original operation must be reconciled; do not repeat the benchmark or declare completion.",systemMessage:"Completion validation result is unknown",platform_blocked:true}'
        return 1
    fi
    if ! jq -e 'type=="object" and .schema=="managed-completion-v1" and (.decision=="pass" or .decision=="repair" or .decision=="platform_blocked") and (.reason|type=="string") and (.evidence_sha256|type=="string" and test("^[a-f0-9]{64}$"))' <<<"$result" >/dev/null; then
        jq -n '{decision:"block",reason:"Completion validation returned an invalid receipt. Preserve the active lifecycle for platform diagnosis.",systemMessage:"Completion validation is invalid",platform_blocked:true}'
        return 1
    fi
    verdict=$(jq -r .decision <<<"$result")
    reason=$(jq -r .reason <<<"$result")
    printf '%s\n' "$result" > "$LOOP_DIR/round-${CURRENT_ROUND}-completion-validation.json"
    [[ "$verdict" == "pass" ]] && return 0
    if [[ "$verdict" == "platform_blocked" ]]; then
        jq -n --arg reason "$reason" '{decision:"block",reason:$reason,systemMessage:"Platform validation is blocked; the optimization round is unchanged",platform_blocked:true}'
        return 1
    fi
    next=$((CURRENT_ROUND + 1))
    if [[ $next -gt $MAX_ITERATIONS ]]; then
        # The negative validation is real; exhausted work cannot become success.
        # Do not reopen methodology with a stale COMPLETE exit reason.
        mv "$STATE_FILE" "$LOOP_DIR/maxiter-state.md"
        rm -f "$LOOP_DIR/.methodology-exit-reason"
        printf '%s\n' "$reason" > "$LOOP_DIR/round-${CURRENT_ROUND}-completion-blocked.md"
        return 1
    fi
    if [[ "$STATE_FILE" != "$LOOP_DIR/state.md" ]]; then
        mv "$STATE_FILE" "$LOOP_DIR/state.md"
    fi
    STATE_FILE="$LOOP_DIR/state.md"
    upsert_state_fields "$STATE_FILE" \
        "${FIELD_CURRENT_ROUND}=$next" "${FIELD_REVIEW_STARTED}=false" \
        "${FIELD_MAINLINE_STALL_COUNT}=0" "${FIELD_DRIFT_STATUS}=${DRIFT_STATUS_NORMAL}"
    rm -f "$LOOP_DIR/.review-phase-started" "$LOOP_DIR/.methodology-exit-reason"
    # Immutable earlier summaries stay intact; only this new native round gets
    # repair instructions. No user approval or numerical claim is synthesized.
    printf '# Required completion corrections\n\n%s\n\nContinue within the approved contract and remaining iteration budget. Keep benchmark definitions frozen. Use the fixed amendment workflow for allowed reference/input compatibility repairs; ask a real question only for a business decision.\n' "$reason" > "$LOOP_DIR/round-${next}-prompt.md"
    jq -n --arg reason "$reason" --argjson round "$next" '{decision:"block",reason:$reason,systemMessage:"Completion validation requires implementation corrections",repair_round:$round}'
    return 1
}
