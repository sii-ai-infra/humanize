# Fixed, bounded DATA interpreter. It grants no permission and runs no effects.
# Source once from the original hook/private prepare, before any state mutation.
_HUMANIZE_LIFECYCLE_READY=false
_HUMANIZE_LIFECYCLE_ROWS=()
readonly HUMANIZE_LIFECYCLE_RULES_SHA256=fa774628d4b648e52645e231e72996c6e23e49c4e32104e2afea0f7238ee070c

lifecycle_rules_block() {
    # This fallback must work even when jq is missing or broken.
    printf '%s\n' '{"decision":"block","reason":"Lifecycle rules are unavailable; preserve the current lifecycle and request platform recovery.","systemMessage":"Lifecycle rules are unavailable","platform_blocked":true}'
}

_lifecycle_rules_read() (
    set -euo pipefail
    umask 077
    local resource="$PLUGIN_ROOT/references/lifecycle-rules-v1.json" private size digest rows
    [[ -f "$resource" && ! -L "$resource" ]] || exit 1
    command -v sha256sum >/dev/null || exit 1
    command -v jq >/dev/null || exit 1
    size=$(wc -c < "$resource") || exit 1
    [[ "$size" -gt 0 && "$size" -le 16384 ]] || exit 1
    private=$(mktemp -d "${TMPDIR:-/tmp}/humanize-lifecycle.XXXXXXXX") || exit 1
    trap 'rm -rf -- "$private"' EXIT
    # Bound the copy independently of the pre-read length; do not re-read the
    # resource after hashing. Hash and jq below consume this same private copy.
    head -c 16385 -- "$resource" > "$private/rules.json" || exit 1
    size=$(wc -c < "$private/rules.json") || exit 1
    [[ "$size" -gt 0 && "$size" -le 16384 ]] || exit 1
    digest=$(sha256sum "$private/rules.json") || exit 1
    [[ "${digest%% *}" == "$HUMANIZE_LIFECYCLE_RULES_SHA256" ]] || exit 1
    # jq is not a strict duplicate-key decoder. The fixed raw SHA and the
    # release/component strict decoder bind the only bytes accepted here.
    rows=$(jq -er '.records | .[] | [.site,.case,.result] | join(":")' "$private/rules.json") || exit 1
    [[ -n "$rows" ]] || exit 1
    printf '%s\n' "$rows"
)

lifecycle_rules_init() {
    [[ "$_HUMANIZE_LIFECYCLE_READY" == false ]] || return 0
    local rows row key seen=" " count=0 required
    _HUMANIZE_LIFECYCLE_ROWS=()
    rows=$(_lifecycle_rules_read) || return 1
    while IFS= read -r row; do
        [[ "$row" != *$'\t'* && "$row" != *' '* ]] || return 1
        key="${row%:*}"
        case "${row##*:}" in
            proceed|request_maxiter|enter_review|skip_review|finalize_same_round|review_next_round|implementation_next_round|skip_privacy|skip_already_active|skip_nonempty_done|enter_methodology_same_round|complete_same_round|stop_same_round|maxiter_same_round|repair_next_round|complete|limit_reached|continue|error|accept|reject) ;;
            *) return 1 ;;
        esac
        # Closed interpreter types: another site's result is never a default
        # branch. Validate all rows now, before any lifecycle effect.
        case "${row%%:*}:${row##*:}" in
            budget_precheck:proceed|budget_precheck:request_maxiter|implementation_complete:request_maxiter|implementation_complete:enter_review|implementation_complete:skip_review|enter_finalize:finalize_same_round|review_issues:review_next_round|implementation_issues:implementation_next_round|methodology_enter:skip_privacy|methodology_enter:skip_already_active|methodology_enter:skip_nonempty_done|methodology_enter:enter_methodology_same_round|methodology_finish:complete_same_round|methodology_finish:stop_same_round|methodology_finish:maxiter_same_round|completion_repair:repair_next_round|completion_repair:maxiter_same_round|node_outcome:complete|node_outcome:limit_reached|node_outcome:continue|node_outcome:error|node_round:accept|node_round:reject) ;;
            *) return 1 ;;
        esac
        [[ "$seen" != *" $key "* ]] || return 1
        seen="$seen$key "
        _HUMANIZE_LIFECYCLE_ROWS+=("$row")
        count=$((count + 1))
        [[ "$count" -le 64 ]] || return 1
    done <<< "$rows"
    [[ "$count" -eq 33 ]] || return 1
    # All possible query keys are resolved before any lifecycle effect. Late
    # branches only access this immutable memory; no late jq/hash/read failures.
    for required in budget_precheck:implementation_within budget_precheck:implementation_beyond budget_precheck:review_within budget_precheck:review_beyond budget_precheck:finalize_within budget_precheck:finalize_beyond implementation_complete:at_or_above implementation_complete:below_with_base implementation_complete:below_without_base enter_finalize:review_passed review_issues:issues_present implementation_issues:continue methodology_enter:privacy methodology_enter:already_active methodology_enter:nonempty_done methodology_enter:enter methodology_finish:complete methodology_finish:stop methodology_finish:maxiter completion_repair:within completion_repair:beyond node_outcome:complete_exit0 node_outcome:maxiter_exit0 node_outcome:state_exit0 node_outcome:state_exit10 node_outcome:finalize_exit0 node_outcome:finalize_exit10 node_outcome:methodology_exit0 node_outcome:methodology_exit10 node_outcome:other node_round:same node_round:next node_round:outside; do
        [[ "$seen" == *" $required "* ]] || return 1
    done
    readonly _HUMANIZE_LIFECYCLE_ROWS
    _HUMANIZE_LIFECYCLE_READY=true
    readonly _HUMANIZE_LIFECYCLE_READY
}

lifecycle_rule() {
    local site="$1" branch="$2" row prefix="$1:$2:"
    [[ "$_HUMANIZE_LIFECYCLE_READY" == true ]] || return 1
    for row in "${_HUMANIZE_LIFECYCLE_ROWS[@]}"; do
        if [[ "$row" == "$prefix"* ]]; then
            LIFECYCLE_RESULT="${row#"$prefix"}"
            return 0
        fi
    done
    return 1
}

lifecycle_rule_or_block() {
    lifecycle_rule "$1" "$2" && return 0
    lifecycle_rules_block
    exit 0
}
