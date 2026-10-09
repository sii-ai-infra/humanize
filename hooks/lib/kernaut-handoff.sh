#!/usr/bin/env bash
# Paired with Kernaut's native Stop continuation. Generic Humanize does not emit
# this metadata: older Codex binaries reject unknown Stop output fields.

kernaut_stage_boundary() {
    local loop_dir="$1" round="$2" summary="$3" review="$4"
    [[ "${KERNELCLI_STAGE_COMPACTION:-0}" == "1" ]] || return 0
    [[ -s "$summary" && -s "$review" ]] || return 0
    # A pre-created summary is not a completed experiment/validation handoff.
    if grep -qE '\[Describe what was implemented|\[List tests/commands run and outcomes\]' "$summary"; then
        return 0
    fi
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
