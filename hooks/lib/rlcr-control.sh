#!/usr/bin/env bash
# Filesystem-facing convergence consumer for the pure RLCR reducer.

[[ -n "${_RLCR_CONTROL_LOADED:-}" ]] && return 0 2>/dev/null || true
_RLCR_CONTROL_LOADED=1

RLCR_CONTROL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RLCR_CONTROL_PLUGIN_ROOT="$(cd "$RLCR_CONTROL_DIR/../.." && pwd)"

RLCR_CONVERGENCE_STATUS=""
RLCR_CONVERGENCE_DIGEST=""
RLCR_CONVERGENCE_INFRA="ok"
RLCR_CONVERGENCE_REASON=""
RLCR_CANDIDATE_FINGERPRINT=""
RLCR_REDUCER_BUDGET=""
RLCR_CONTROL_ACTIVE=false
RLCR_CONVERGENCE_PATH_RESOLVED=""

rlcr_control_has_trusted_pipeline() {
    local project_root="$1"
    [[ -e "$project_root/.pipeline/state.json" \
       || -L "$project_root/.pipeline/state.json" \
       || -f "$project_root/.pipeline/trust-manifest.json" \
       || -f "$project_root/.pipeline/hook-tcb.json" ]]
}

rlcr_control_enabled() {
    local project_root="$1"
    local state="$project_root/.pipeline/state.json"
    local marker="$project_root/.pipeline/loop_provenance.json"
    case "${RLCR_REDUCER_ENABLED:-auto}" in
        true|1) return 0 ;;
        false|0) return 1 ;;
    esac

    # KOP's management-owned pipeline state is the authoritative switch.  The
    # candidate ACL may read this file but cannot rewrite it or replace it via
    # .pipeline/.  A missing, unreadable, symlinked, or malformed authority in
    # an otherwise trusted KOP workspace therefore enables the strict consumer
    # (fail closed) instead of silently falling back to the legacy adapter.
    if rlcr_control_has_trusted_pipeline "$project_root"; then
        [[ -f "$state" && ! -L "$state" && -r "$state" ]] || return 0
        local decision
        if ! decision=$(jq -er --arg root "$project_root" '
            if type != "object" then error("pipeline state must be an object")
            elif ((.stage // "") | type) != "string"
              or ((.loop_mode // "") | type) != "string"
            then error("pipeline control fields must be strings")
            elif .task_dir != $root then error("pipeline state is not bound to this project")
            elif has("rlcr_control") and (.rlcr_control | type) != "object"
            then error("pipeline control credential must be an object")
            elif (.rlcr_control | type) == "object"
              and (.rlcr_control | has("enabled"))
              and (.rlcr_control.enabled | type) != "boolean"
            then error("pipeline control enabled flag must be boolean")
            elif (.rlcr_control | type) == "object"
              and .rlcr_control.enabled == false
              and .rlcr_control.schema_version == "rlcr-control-v1"
            then "disable"
            elif .stage == "execute" and .loop_mode == "rlcr" then "enable"
            else "disable"
            end
        ' "$state" 2>/dev/null); then
            return 0
        fi
        [[ "$decision" == "enable" ]]
        return
    fi

    # Standalone Humanize compatibility: historical projects have no trusted
    # pipeline state and opt into W4b through the original marker.  Reject a
    # symlinked marker; new KOP workspaces never reach this compatibility path.
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    [[ "$(jq -r '.loop_mode // empty' "$marker" 2>/dev/null || true)" == "rlcr" \
       && "$(jq -r '.reducer_version // empty' "$marker" 2>/dev/null || true)" == "$RLCR_REDUCER_VERSION" ]]
}

rlcr_control_config_value() {
    local project_root="$1" key="$2"
    local state="$project_root/.pipeline/state.json"

    # Once KOP state exists, marker contents are no longer configuration
    # authority either.  Invalid or pre-migration state yields an empty value,
    # causing the caller to use its compiled-in fail-closed defaults.
    if rlcr_control_has_trusted_pipeline "$project_root"; then
        [[ -f "$state" && ! -L "$state" && -r "$state" ]] || return 0
        jq -r --arg key "$key" --arg version "$RLCR_REDUCER_VERSION" \
            --arg root "$project_root" '
            if type == "object"
               and .task_dir == $root
               and .stage == "execute"
               and .loop_mode == "rlcr"
               and ((.rlcr_control // null) | type) == "object"
               and .rlcr_control.schema_version == "rlcr-control-v1"
               and .rlcr_control.enabled == true
               and .rlcr_control.reducer_version == $version
            then .rlcr_control[$key] // empty
            else empty
            end
        ' "$state" 2>/dev/null || true
        return 0
    fi

    jq -r --arg key "$key" '.[$key] // empty' \
        "$project_root/.pipeline/loop_provenance.json" 2>/dev/null || true
}

rlcr_control_resolve_path() {
    local project_root="$1" configured="$2" fallback="$3" candidate
    candidate="${configured:-$fallback}"
    if [[ "$candidate" == /* ]]; then
        case "$candidate" in "$project_root"/*) printf '%s\n' "$candidate" ;; *) return 1 ;; esac
    elif [[ "$candidate" != *$'\n'* && "$candidate" != ../* && "$candidate" != */../* && "$candidate" != */.. ]]; then
        printf '%s/%s\n' "$project_root" "$candidate"
    else
        return 1
    fi
}

rlcr_legacy_convergence() {
    local phase="$1" reviewer_signal="$2" status
    case "$phase:$reviewer_signal" in
        review:*|finalize:*|methodology-analysis:COMPLETE|implementation:COMPLETE)
            status=pass ;;
        methodology-analysis:STOP)
            status=exhausted ;;
        *) status=below_target ;;
    esac
    RLCR_CONVERGENCE_STATUS="$status"
    RLCR_CONVERGENCE_DIGEST=$(printf 'rlcr-legacy-convergence-v1\n%s\n%s\n' \
        "$phase" "$status" | rlcr_sha256_stream)
    RLCR_CONVERGENCE_INFRA=ok
    RLCR_CONVERGENCE_REASON=legacy_compatibility
}

rlcr_candidate_fingerprint() {
    local project_root="$1"
    if git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        {
            git -C "$project_root" rev-parse --verify HEAD 2>/dev/null || printf 'no-head\n'
            git -C "$project_root" rev-parse --verify HEAD^{tree} 2>/dev/null || printf 'no-tree\n'
            git -C "$project_root" status --porcelain=v1 --untracked-files=all 2>/dev/null || true
        } | rlcr_sha256_stream
    else
        printf 'rlcr-no-git-candidate\n' | rlcr_sha256_stream
    fi
}

rlcr_convergence_error() {
    local status="$1" reason="$2"
    RLCR_CONVERGENCE_STATUS="$status"
    RLCR_CONVERGENCE_DIGEST=$(printf 'rlcr-convergence-error-v1\n%s\n%s\n' \
        "$status" "$reason" | rlcr_sha256_stream)
    RLCR_CONVERGENCE_INFRA=ok
    RLCR_CONVERGENCE_REASON="$reason"
}

# Run the evaluator over already-persisted evidence.  This command never runs a
# benchmark.  All failures become evaluator_error data and return success to
# prevent `set -e` from turning fail-closed policy into a hook runtime crash.
rlcr_control_evaluate() {
    local project_root="$1" loop_dir="$2" phase="$3" reviewer_signal="$4"
    if ! rlcr_control_enabled "$project_root"; then
        RLCR_CONTROL_ACTIVE=false
        rlcr_legacy_convergence "$phase" "$reviewer_signal"
        RLCR_CANDIDATE_FINGERPRINT=$(rlcr_candidate_fingerprint "$project_root")
        return 0
    fi
    RLCR_CONTROL_ACTIVE=true

    local convergence_config evaluator_config freshness_config
    local convergence_path evaluator_path freshness_path
    convergence_config="${RLCR_CONVERGENCE_PATH:-$(rlcr_control_config_value "$project_root" convergence_path)}"
    evaluator_config="${RLCR_CONVERGENCE_EVALUATOR:-$(rlcr_control_config_value "$project_root" convergence_evaluator)}"
    freshness_config="${RLCR_FRESHNESS_BINDINGS_PATH:-$(rlcr_control_config_value "$project_root" freshness_bindings)}"
    convergence_path=$(rlcr_control_resolve_path "$project_root" "$convergence_config" convergence.json) || {
        rlcr_convergence_error evaluator_error invalid_convergence_path
        return 0
    }
    RLCR_CONVERGENCE_PATH_RESOLVED="$convergence_path"
    evaluator_path=$(rlcr_control_resolve_path "$project_root" "$evaluator_config" bench/promotion_evaluator.py) || {
        rlcr_convergence_error evaluator_error invalid_evaluator_path
        return 0
    }
    freshness_path=$(rlcr_control_resolve_path "$project_root" "$freshness_config" .pipeline/promotion-freshness.json) || {
        rlcr_convergence_error evaluator_error invalid_freshness_path
        return 0
    }

    if [[ "${RLCR_CONVERGENCE_CONSUME_ONLY:-false}" != "true" ]]; then
        if [[ ! -f "$evaluator_path" || -L "$evaluator_path" ]]; then
            rlcr_convergence_error evaluator_error evaluator_missing
            return 0
        fi
        local evaluator_status=0
        local -a evaluator_command=()
        if [[ "$evaluator_path" == *.py ]]; then
            evaluator_command=("${PYTHON:-python3}" "$evaluator_path")
        else
            evaluator_command=("$evaluator_path")
        fi
        if "${evaluator_command[@]}" \
            --evidence "$project_root/analysis/promotion_evidence.json" \
            --gates "$project_root/bench/gates.json" \
            --inputs "$project_root/baseline/inputs.json" \
            --leaderboard "$project_root/leaderboard.csv" \
            --freshness-bindings "$freshness_path" \
            --output "$convergence_path" \
            > "$loop_dir/convergence-evaluator.log" 2>&1; then
            evaluator_status=0
        else
            evaluator_status=$?
        fi
        if [[ "$evaluator_status" -ne 0 ]]; then
            rlcr_convergence_error evaluator_error "evaluator_exit_${evaluator_status}"
            return 0
        fi
    fi

    local validation validation_status=0
    if validation=$("${PYTHON:-python3}" \
        "$RLCR_CONTROL_PLUGIN_ROOT/scripts/validate-rlcr-convergence.py" \
        "$convergence_path" 2>> "$loop_dir/convergence-evaluator.log"); then
        validation_status=0
    else
        validation_status=$?
    fi
    if [[ "$validation_status" -ne 0 ]] || ! jq -e . >/dev/null 2>&1 <<< "$validation"; then
        rlcr_convergence_error evaluator_error convergence_validator_failed
        return 0
    fi
    RLCR_CONVERGENCE_STATUS=$(jq -r '.status' <<< "$validation")
    RLCR_CONVERGENCE_DIGEST=$(jq -r '.digest' <<< "$validation")
    RLCR_CONVERGENCE_INFRA=$(jq -r '.infra' <<< "$validation")
    RLCR_CONVERGENCE_REASON=$(jq -r '.reason' <<< "$validation")
    if [[ ! "$RLCR_CONVERGENCE_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
        local invalid_status="$RLCR_CONVERGENCE_STATUS"
        rlcr_convergence_error "$invalid_status" "$RLCR_CONVERGENCE_REASON"
    fi
    if [[ -s "$convergence_path" && "$RLCR_CONVERGENCE_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
        local snapshot="$loop_dir/convergence-${RLCR_CONVERGENCE_DIGEST}.json"
        local snapshot_temp="${snapshot}.prepare.$$" snapshot_validation snapshot_digest
        if ! cp "$convergence_path" "$snapshot_temp" 2>/dev/null; then
            rlcr_convergence_error evaluator_error convergence_snapshot_failed
            return 0
        fi
        snapshot_validation=$("${PYTHON:-python3}" \
            "$RLCR_CONTROL_PLUGIN_ROOT/scripts/validate-rlcr-convergence.py" \
            "$snapshot_temp" 2>> "$loop_dir/convergence-evaluator.log" || true)
        snapshot_digest=$(jq -r '.digest // empty' <<< "$snapshot_validation" 2>/dev/null || true)
        if [[ "$snapshot_digest" != "$RLCR_CONVERGENCE_DIGEST" ]]; then
            rm -f "$snapshot_temp"
            rlcr_convergence_error stale convergence_changed_during_consumption
            return 0
        fi
        mv "$snapshot_temp" "$snapshot"
    fi
    RLCR_CANDIDATE_FINGERPRINT=$(rlcr_candidate_fingerprint "$project_root")
}

rlcr_control_decide() {
    local project_root="$1" loop_dir="$2" phase="$3" reviewer_signal="$4"
    local current_round="$5" max_iterations="$6" closeout_steps="$7"
    local max_closeout_steps="$8" prior_digest="${9:-}" prior_fingerprint="${10:-}"
    rlcr_control_evaluate "$project_root" "$loop_dir" "$phase" "$reviewer_signal"

    # Finalize is allowed to change the candidate, but an unchanged convergence
    # digest can no longer prove freshness for that changed candidate/commit.
    if [[ "$phase" == "finalize" && -n "$prior_fingerprint" \
       && "$RLCR_CANDIDATE_FINGERPRINT" != "$prior_fingerprint" \
       && "$RLCR_CONVERGENCE_DIGEST" == "$prior_digest" ]]; then
        RLCR_CONVERGENCE_STATUS=stale
        RLCR_CONVERGENCE_REASON=finalize_changed_candidate_without_new_convergence
    fi

    if [[ "$RLCR_CONTROL_ACTIVE" != "true" \
       && ( "$phase" == "review" || "$phase" == "finalize" ) ]]; then
        # Generic pre-W4b loops exempted review/finalize from the hard round
        # limit and had no closeout counter.  Do not impose W4b's new bounded
        # closeout budget on those historical phases.
        RLCR_REDUCER_BUDGET=remaining
    elif [[ "$RLCR_CONTROL_ACTIVE" != "true" \
         && "$current_round" =~ ^[0-9]+$ && "$max_iterations" =~ ^[0-9]+$ \
         && $((current_round + 1)) -gt "$max_iterations" ]]; then
        # Legacy implementation rounds retain their historical hard max. KOP
        # loops carrying reducer provenance use bounded closeout_only instead.
        RLCR_REDUCER_BUDGET=exhausted
    else
        RLCR_REDUCER_BUDGET=$(rlcr_reduce_budget "$phase" "$RLCR_CONVERGENCE_STATUS" \
            "$current_round" "$max_iterations" "$closeout_steps" "$max_closeout_steps")
    fi
    local cancel_requested=false infra="$RLCR_CONVERGENCE_INFRA"
    [[ -f "$loop_dir/.cancel-requested" ]] && cancel_requested=true
    if [[ -n "${RLCR_INFRA_STATUS:-}" ]]; then
        infra="$RLCR_INFRA_STATUS"
    fi
    reduce "$phase" "$reviewer_signal" "$RLCR_CONVERGENCE_STATUS" \
        "$RLCR_REDUCER_BUDGET" "$infra" "$cancel_requested" >/dev/null
}
