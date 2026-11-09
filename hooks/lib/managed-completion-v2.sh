# Fixed managed v2 protocol. Metrics/AC and owner authority belong to Node;
# this library never infers a verdict from prose or advances rounds itself.
managed_v2_block() {
    jq -n --arg reason "$1" --arg code "$2" '{decision:"block",reason:$reason,systemMessage:"Managed pipeline requires reconciliation",managed_v2_error:$code}'
}

managed_v2_mode() {
    if [[ "${HUMANIZE_MANAGED_PIPELINE:-}" != "v2" || "${HUMANIZE_MANAGED_RELIABILITY_V1+x}" == "x" ]]; then
        managed_v2_block "The v2 callback has no unambiguous protected mode. Preserve the original lifecycle." "unsupported_mode"
        return 1
    fi
    if [[ "${PLUGIN_ROOT:-}" != /* || ! -f "$PLUGIN_ROOT/scripts/validate-managed-receipt-v2.py" || ! -r "$PLUGIN_ROOT/scripts/validate-managed-receipt-v2.py" || -L "$PLUGIN_ROOT/scripts/validate-managed-receipt-v2.py" || ! -x /usr/bin/python3.12 ]]; then
        managed_v2_block "The fixed isolated v2 decoder is unavailable." "missing_v2_runtime"
        return 1
    fi
}

managed_v2_decode() {
    local phase="$1"
    # -I is essential: task cwd/PYTHONPATH/site cannot replace the decoder's
    # stdlib imports. Do not use the script's shebang or PATH interpreter.
    /usr/bin/python3.12 -I -S -B "$PLUGIN_ROOT/scripts/validate-managed-receipt-v2.py" --phase "$phase"
}

managed_v2_apply() {
    local receipt="$1" phase="$2"
    local helper="$PLUGIN_ROOT/scripts/apply-managed-repair-v2.py"
    if [[ ! -f "$helper" || ! -r "$helper" || -L "$helper" || -z "${HUMANIZE_MANAGED_REPAIR_PLAN_V2:-}" || -z "${HUMANIZE_MANAGED_REPAIR_OPERATION_V2:-}" || -z "${HUMANIZE_MANAGED_REPAIR_INTENT_V2:-}" ]]; then
        managed_v2_block "The original repair operation has no fixed prepared native helper/plan. Reconcile it; do not repeat measurement or invent another round." "repair_unavailable"
        return 1
    fi
    # The fixed helper alone owns native budget/state changes. The plan is
    # supplied by the protected controller, not by candidate/task arguments.
    # A known operation preserves native stdout: repair_round block for a
    # next round, empty on maxiter. Runtime failures emit stderr/nonzero.
    if ! printf '%s\n' "$receipt" | /usr/bin/python3.12 -I -S -B "$helper" \
        --phase "$phase" --plan "$HUMANIZE_MANAGED_REPAIR_PLAN_V2" \
        --operation "$HUMANIZE_MANAGED_REPAIR_OPERATION_V2" \
        --intent "$HUMANIZE_MANAGED_REPAIR_INTENT_V2" \
        --loop-dir "$LOOP_DIR" --expected-round "$CURRENT_ROUND"; then
        managed_v2_block "The original native repair operation is unresolved. Preserve its before/after records." "repair_unresolved"
    fi
    return 1
}

managed_v2_disposition() {
    local receipt="$1" phase="$2" decision reason
    decision=$(jq -r .decision <<<"$receipt")
    reason=$(jq -r .reason <<<"$receipt")
    case "$decision" in
        pass)
            if [[ "$phase" != "completion" ]]; then
                managed_v2_block "A round cannot grant terminal pass." "invalid_receipt"
                return 1
            fi
            return 0 ;;
        continue)
            if [[ "$phase" != "round" ]]; then
                managed_v2_block "A completion callback cannot return continue." "invalid_receipt"
                return 1
            fi
            return 0 ;;
        pause)
            jq -n --arg reason "$reason" --arg outcome "$(jq -r .outcome <<<"$receipt")" \
                --arg evidence "$(jq -r .evidence_sha256 <<<"$receipt")" \
                '{decision:"block",reason:$reason,systemMessage:"The native round and its budget are unchanged",managed_v2_decision:"pause",managed_v2_outcome:$outcome,managed_v2_evidence_sha256:$evidence}'
            return 1 ;;
        repair)
            # Ordinary round repair is not a native transition. The one
            # explicit exception consumes the separately authorized owner CAS;
            # its closed tuple is also checked by the fixed decoder.
            if [[ "$phase" != completion ]] && { [[ "$phase" != round ]] || [[ "$(jq -r .outcome <<<"$receipt")" != unmeasurable ]] || [[ "$(jq -r .reason_code <<<"$receipt")" != owner_requested_repair ]]; }; then
                managed_v2_block "This round receipt cannot request a native repair operation." "invalid_receipt"
                return 1
            fi
            managed_v2_apply "$receipt" "$phase"
            return 1 ;;
        *)
            managed_v2_block "The v2 disposition is invalid. Preserve the original operation." "invalid_receipt"
            return 1 ;;
    esac
}

managed_completion_validation() {
    managed_v2_mode || return 1
    local result helper="$PLUGIN_ROOT/scripts/run-round-benchmark-v2.py"
    if [[ "${HUMANIZE_COMPLETION_VALIDATOR:-}" != /* || ! -f "$HUMANIZE_COMPLETION_VALIDATOR" || ! -x "$HUMANIZE_COMPLETION_VALIDATOR" || -L "$HUMANIZE_COMPLETION_VALIDATOR" ]]; then
        managed_v2_block "The fixed v2 completion callback is unavailable. No completion is authorized." "missing_callback"
        return 1
    fi
    if [[ ! -f "$helper" || ! -r "$helper" || -L "$helper" || "${PROJECT_ROOT:-}" != /* || "${LOOP_DIR:-}" != /* || -z "${CURRENT_ROUND:-}" ]]; then
        managed_v2_block "The original completion operation has no fixed staging helper or native context." "missing_completion_operation"
        return 1
    fi
    # Reuse the round adapter's original descriptor, lock and atomic publisher.
    # Native disposition only sees the exact receipt committed for this gate.
    if ! result=$(set -o pipefail; /usr/bin/python3.12 -I -S -B "$helper" --completion \
        --project-root "$PROJECT_ROOT" --loop-dir "$LOOP_DIR" --round "$CURRENT_ROUND" \
        | managed_v2_decode completion); then
        managed_v2_block "The completion callback did not return an exact v2 receipt. Reconcile its original operation." "invalid_receipt"
        return 1
    fi
    managed_v2_disposition "$result" completion
}

managed_round_status_validation_v2() {
    managed_v2_mode || return 1
    local receipt="${HUMANIZE_MANAGED_ROUND_RECEIPT_V2:-}" result
    # The v2 runner writes one staged status outside the guarded loop. Reading
    # that same protected response avoids consuming the broker operation twice.
    if [[ "$receipt" != /* || ! -f "$receipt" || ! -r "$receipt" || -L "$receipt" ]]; then
        managed_v2_block "The v2 round has no staged response from its original operation. Do not use a legacy result file." "missing_round_receipt"
        return 1
    fi
    if ! result=$(managed_v2_decode round < "$receipt"); then
        managed_v2_block "The original round response is not an exact v2 receipt." "invalid_receipt"
        return 1
    fi
    managed_v2_disposition "$result" round
}
