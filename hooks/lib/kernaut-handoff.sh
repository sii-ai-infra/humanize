#!/usr/bin/env bash
# Paired with Kernaut's native Stop continuation. Generic Humanize does not emit
# this metadata: older Codex binaries reject unknown Stop output fields.

kernaut_stage_boundary() {
    local loop_dir="$1" round="$2" summary="$3" review="$4" project_root="$5"
    [[ "${KERNELCLI_STAGE_COMPACTION:-0}" == "1" ]] || return 0
    [[ -s "$summary" && -s "$review" ]] || return 0
    # A pre-created summary is not a completed experiment/validation handoff.
    if grep -qE '\[Describe what was implemented|\[Describe what was done|\[List tests/commands run and outcomes\]' "$summary"; then
        return 0
    fi
    # Maintenance-only work does not start another optimization stage. Require
    # an explicit stage and a real saved experiment/validation record.
    grep -qE '^[-*] Stage: optimization[[:space:]]*$' "$summary" || return 0
    local evidence
    evidence=$(sed -n 's/^[-*] Validation evidence: //p' "$summary" | head -n 1)
    [[ -n "$evidence" ]] || return 0
    [[ "$evidence" = /* ]] || evidence="$project_root/$evidence"
    [[ -s "$evidence" ]] || return 0
    local fingerprint boundary_id pending_tmp
    fingerprint=$(sha256sum "$review" | cut -d ' ' -f 1)
    boundary_id="$(basename "$loop_dir"):round-${round}:${fingerprint}"
    pending_tmp=$(mktemp "$loop_dir/.pending-stage-compaction.XXXXXX")
    jq -n --arg id "$boundary_id" \
        --arg receiptPath "$loop_dir/round-${round}-compact.json" \
        '{id: $id, receiptPath: $receiptPath}' > "$pending_tmp"
    mv "$pending_tmp" "$loop_dir/pending-stage-compaction.json"
    cat "$loop_dir/pending-stage-compaction.json"
}

# Short facts belong in the existing summary, not another context framework.
kernaut_append_handoff_template() {
    local summary="$1" loop_dir="$2" round="$3"
    cat >> "$summary" <<EOF

## Optimization Handoff
- Stage: [optimization or maintenance; maintenance includes format-only work/waiting]
- Validation evidence: .humanize/rlcr/$(basename "$loop_dir")/round-${round}-benchmark.md
- Constraints: [contract/case list/harness and known knowledge/resource identities; latest requirements]
- Current candidate: [source hashes/Git version and receipt]
- Best valid candidate: [source hashes/Git version and receipt, or unknown]
- Full correctness/device coverage/G/min per-case: [facts or unknown]
- Failed cases/unresolved review/next hypothesis: [short facts and evidence paths]

## Knowledge Decision
- Task facts: [actual computation/fusion, shape/stride/dtype and index/numeric/alias rules; source paths; unknowns]
- Method conditions: [ID/reference; applicable/conditional/incompatible/needs_probe; evidence, missing conditions and keep/reject reason]
- Selected experiment: [method ID or own hypothesis; intervention and distinguishing check; observed result/receipt or planned]
- Retrieval decision: [stop because the next experiment/check is defined, or continue for a named question that changes the choice]

Use exactly \`- Stage: optimization\` only for a real optimization experiment with
saved validation. Validation evidence is one local, nonempty receipt/log path;
replace the default if needed. Missing measurements remain unknown.
Keep knowledge decisions short; reuse saved references. A returned method is not
automatically selected, and a planned experiment is not a validation result.
EOF
}
