#!/usr/bin/env bash
#
# Pure RLCR convergence reducer and its deterministic protocol helpers.
#
# `reduce` is intentionally free of filesystem and process side effects.  The
# Stop hook gathers evidence, calls this function, then applies the returned
# transition through the existing fenced state/outbox writer.

[[ -n "${_RLCR_REDUCER_LOADED:-}" ]] && return 0 2>/dev/null || true
_RLCR_REDUCER_LOADED=1

RLCR_REDUCER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$RLCR_REDUCER_DIR/rlcr-protocol.sh"
readonly RLCR_DEFAULT_MAX_CLOSEOUT_STEPS=2

RLCR_REDUCER_NEXT_PHASE=""
RLCR_REDUCER_ACTION=""
RLCR_REDUCER_REASON=""

rlcr_reducer_transition() {
    RLCR_REDUCER_NEXT_PHASE="$1"
    RLCR_REDUCER_ACTION="$2"
    RLCR_REDUCER_REASON="$3"
}

rlcr_reviewer_signal_valid() {
    case "$1" in
        COMPLETE|STOP|mainline_drift|ADVANCED|STALLED|REGRESSED|none|review_issue|review_issue:P[0-9]|review_issueP[0-9]|review_issue\[P[0-9]\])
            return 0 ;;
        *) return 1 ;;
    esac
}

rlcr_reviewer_signal_reachable() {
    local phase="$1" reviewer_signal="$2"
    case "$phase:$reviewer_signal" in
        implementation:COMPLETE|implementation:STOP|implementation:mainline_drift|implementation:ADVANCED|implementation:STALLED|implementation:REGRESSED|implementation:none)
            return 0 ;;
        review:none|review:review_issue|review:review_issue:P[0-9]|review:review_issueP[0-9]|review:review_issue\[P[0-9]\])
            return 0 ;;
        finalize:COMPLETE|finalize:none|finalize:review_issue|finalize:review_issue:P[0-9]|finalize:review_issueP[0-9]|finalize:review_issue\[P[0-9]\])
            return 0 ;;
        methodology-analysis:COMPLETE|methodology-analysis:STOP|methodology-analysis:none)
            return 0 ;;
        terminal:*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

rlcr_reviewer_signal_is_issue() {
    case "$1" in review_issue*) return 0 ;; *) return 1 ;; esac
}

# reduce(phase, reviewer_signal, convergence, budget, infra,
#        cancel_requested) -> transition(next_phase, payload)
#
# The function sets RLCR_REDUCER_* and prints one compact JSON transition.
# Invalid and unreachable tuples are deliberately mapped to terminal_blocked.
reduce() {
    local phase="${1:-}" reviewer_signal="${2:-}" convergence="${3:-}"
    local budget="${4:-}" infra="${5:-}" cancel_requested="${6:-}"

    RLCR_REDUCER_NEXT_PHASE=""
    RLCR_REDUCER_ACTION=""
    RLCR_REDUCER_REASON=""

    # Domain validation is a safety/evidence failure and therefore has the
    # highest priority, even when a cancellation or budget signal coexists.
    case "$phase" in
        implementation|review|finalize|methodology-analysis|terminal) ;;
        *) rlcr_reducer_transition terminal terminal_blocked invalid_phase ;;
    esac
    if [[ -z "$RLCR_REDUCER_ACTION" ]] && ! rlcr_reviewer_signal_valid "$reviewer_signal"; then
        rlcr_reducer_transition terminal terminal_blocked invalid_reviewer_signal
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" ]] \
       && ! rlcr_reviewer_signal_reachable "$phase" "$reviewer_signal"; then
        rlcr_reducer_transition terminal terminal_blocked unreachable_phase_reviewer_signal
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" ]]; then
        case "$convergence" in
            pass|below_target|group_stalled|exhausted|stale|missing|evaluator_error) ;;
            *) rlcr_reducer_transition terminal terminal_blocked invalid_convergence ;;
        esac
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" ]]; then
        case "$budget" in
            remaining|exhausted|closeout_only) ;;
            *) rlcr_reducer_transition terminal terminal_blocked invalid_budget ;;
        esac
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" ]]; then
        case "$infra" in
            ok|device_unavailable|tunnel_down|tcb_tampered) ;;
            *) rlcr_reducer_transition terminal terminal_blocked invalid_infra ;;
        esac
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" && "$cancel_requested" != "true" && "$cancel_requested" != "false" ]]; then
        rlcr_reducer_transition terminal terminal_blocked invalid_cancel_signal
    fi

    # Priority 1: security, infrastructure, and evidence validity fail closed.
    if [[ -z "$RLCR_REDUCER_ACTION" && "$infra" != "ok" ]]; then
        rlcr_reducer_transition terminal terminal_blocked "infra_${infra}"
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" ]]; then
        case "$convergence" in
            stale|missing|evaluator_error)
                rlcr_reducer_transition terminal terminal_blocked "convergence_${convergence}"
                ;;
        esac
    fi

    # Priority 2: an otherwise valid transition honors explicit cancellation.
    if [[ -z "$RLCR_REDUCER_ACTION" && "$cancel_requested" == "true" ]]; then
        rlcr_reducer_transition terminal terminal_cancelled cancel_requested
    fi

    # Terminal is absorbing.  Only a tuple that proves the already-selected
    # terminal result is accepted; every other re-entry is unreachable.
    if [[ -z "$RLCR_REDUCER_ACTION" && "$phase" == "terminal" ]]; then
        if [[ "$convergence" == "pass" && "$reviewer_signal" == "COMPLETE" ]]; then
            rlcr_reducer_transition terminal terminal_success terminal_success_replay
        elif [[ "$convergence" == "exhausted" ]]; then
            rlcr_reducer_transition terminal terminal_exhausted terminal_exhausted_replay
        elif [[ "$budget" == "exhausted" ]]; then
            rlcr_reducer_transition terminal terminal_budget terminal_budget_replay
        else
            rlcr_reducer_transition terminal terminal_blocked unreachable_terminal_tuple
        fi
    fi

    # Priority 3: closeout_only is the sole budget exception.  It is legal only
    # for a passing convergence result; the caller bounds it with a persisted
    # closeout counter.  A fully exhausted budget never starts another step.
    if [[ -z "$RLCR_REDUCER_ACTION" && "$budget" == "exhausted" ]]; then
        if [[ "$phase" == "methodology-analysis" ]]; then
            rlcr_reducer_transition terminal terminal_budget budget_exhausted
        else
            rlcr_reducer_transition methodology-analysis terminal_budget budget_exhausted
        fi
    fi
    if [[ -z "$RLCR_REDUCER_ACTION" && "$budget" == "closeout_only" && "$convergence" != "pass" ]]; then
        rlcr_reducer_transition terminal terminal_budget closeout_budget_requires_pass
    fi

    # Priority 4: a performance pass starts or advances closeout.  It cannot
    # become terminal_success until the finalize phase itself has completed.
    if [[ -z "$RLCR_REDUCER_ACTION" && "$convergence" == "pass" ]]; then
        case "$phase" in
            implementation)
                if [[ "$reviewer_signal" == "STOP" || "$reviewer_signal" == "mainline_drift" ]]; then
                    rlcr_reducer_transition methodology-analysis terminal_exhausted reviewer_circuit_breaker
                elif [[ "$reviewer_signal" == "COMPLETE" ]]; then
                    rlcr_reducer_transition review enter_review implementation_complete_requires_review
                else
                    rlcr_reducer_transition implementation continue_closeout performance_pass_ac_incomplete
                fi
                ;;
            review)
                if rlcr_reviewer_signal_is_issue "$reviewer_signal"; then
                    rlcr_reducer_transition review continue_closeout review_issues_require_closeout
                elif [[ "$reviewer_signal" == "STOP" || "$reviewer_signal" == "mainline_drift" ]]; then
                    rlcr_reducer_transition review continue_closeout passing_candidate_requires_review_resolution
                else
                    rlcr_reducer_transition finalize continue_closeout review_passed_requires_finalize
                fi
                ;;
            finalize)
                if rlcr_reviewer_signal_is_issue "$reviewer_signal"; then
                    rlcr_reducer_transition review continue_closeout finalize_found_review_issue
                elif [[ "$reviewer_signal" == "COMPLETE" || "$reviewer_signal" == "none" ]]; then
                    rlcr_reducer_transition terminal terminal_success convergence_and_closeout_complete
                else
                    rlcr_reducer_transition finalize continue_closeout finalize_incomplete
                fi
                ;;
            methodology-analysis)
                if [[ "$reviewer_signal" == "COMPLETE" ]]; then
                    rlcr_reducer_transition terminal terminal_success methodology_complete_after_success
                elif [[ "$reviewer_signal" == "STOP" ]]; then
                    rlcr_reducer_transition terminal terminal_exhausted methodology_complete_after_exhaustion
                else
                    rlcr_reducer_transition terminal terminal_blocked invalid_methodology_pass_tuple
                fi
                ;;
        esac
    fi

    # Priority 5: non-passing, valid convergence states drive optimization.
    if [[ -z "$RLCR_REDUCER_ACTION" ]]; then
        case "$convergence" in
            exhausted)
                if [[ "$phase" == "methodology-analysis" ]]; then
                    rlcr_reducer_transition terminal terminal_exhausted methodology_complete_after_exhaustion
                else
                    rlcr_reducer_transition methodology-analysis terminal_exhausted convergence_exhausted
                fi
                ;;
            group_stalled)
                rlcr_reducer_transition implementation continue_pivot convergence_group_stalled
                ;;
            below_target)
                case "$phase:$reviewer_signal" in
                    methodology-analysis:STOP)
                        rlcr_reducer_transition terminal terminal_exhausted methodology_complete_after_stop ;;
                    methodology-analysis:*)
                        rlcr_reducer_transition terminal terminal_blocked invalid_methodology_nonpass_tuple ;;
                    *:STOP|*:mainline_drift)
                        rlcr_reducer_transition methodology-analysis terminal_exhausted reviewer_circuit_breaker ;;
                    *:STALLED|*:REGRESSED)
                        rlcr_reducer_transition implementation continue_pivot reviewer_requests_pivot ;;
                    *)
                        rlcr_reducer_transition implementation continue_optimize convergence_below_target ;;
                esac
                ;;
            *)
                rlcr_reducer_transition terminal terminal_blocked unreachable_reducer_tuple
                ;;
        esac
    fi

    if [[ "${RLCR_REDUCER_NO_OUTPUT:-false}" == "true" ]]; then
        return 0
    elif command -v jq >/dev/null 2>&1; then
        jq -cn \
            --arg next_phase "$RLCR_REDUCER_NEXT_PHASE" \
            --arg kind "$RLCR_REDUCER_ACTION" \
            --arg reason "$RLCR_REDUCER_REASON" \
            '{next_phase:$next_phase,payload:{kind:$kind,reason:$reason}}'
    else
        printf '%s\t%s\t%s\n' \
            "$RLCR_REDUCER_NEXT_PHASE" "$RLCR_REDUCER_ACTION" "$RLCR_REDUCER_REASON"
    fi
}

# Compute the persisted budget domain.  Reaching max_iterations does not
# discard a passing final measurement: at most max_closeout_steps nonterminal
# closeout transitions are admitted.  Finalize may consume the terminal success
# at exactly the bound, but no additional closeout transition may start.
rlcr_reduce_budget() {
    local phase="$1" convergence="$2" current_round="$3" max_iterations="$4"
    local closeout_steps="$5" max_closeout_steps="$6"
    if ! [[ "$current_round" =~ ^[0-9]+$ && "$max_iterations" =~ ^[0-9]+$ \
         && "$closeout_steps" =~ ^[0-9]+$ && "$max_closeout_steps" =~ ^[0-9]+$ ]]; then
        printf 'exhausted\n'
        return
    fi
    if [[ $((current_round + 1)) -le "$max_iterations" ]]; then
        printf 'remaining\n'
    elif [[ "$convergence" == "pass" \
         && ( "$closeout_steps" -lt "$max_closeout_steps" \
              || ( "$phase" == "finalize" && "$closeout_steps" -eq "$max_closeout_steps" ) ) ]]; then
        printf 'closeout_only\n'
    else
        printf 'exhausted\n'
    fi
}
