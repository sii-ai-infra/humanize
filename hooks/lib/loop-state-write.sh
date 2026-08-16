#!/usr/bin/env bash
#
# Zero-dependency RLCR control-plane primitives.
#
# This file is intentionally a leaf module: sourcing it performs no project,
# config, template, jq, or Codex discovery.  It is safe for the Bash
# PostToolUse hook, which runs for every Bash command in every project.

[[ -n "${_RLCR_STATE_WRITE_LOADED:-}" ]] && return 0 2>/dev/null || true
_RLCR_STATE_WRITE_LOADED=1

RLCR_STATE_WRITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$RLCR_STATE_WRITE_DIR/rlcr-protocol.sh"

RLCR_LOCK_TOKEN=""
RLCR_LOCK_DIR=""
RLCR_ACTION_ID=""
RLCR_ACTION_EPOCH=""
RLCR_ACTION_MODE=""
RLCR_ACTION_PHASE=""
RLCR_ACTION_ROUND=""
RLCR_OBSERVED_GENERATION=""
RLCR_OBSERVED_PHASE=""
RLCR_INFLIGHT_OWNER_PID=""
RLCR_INFLIGHT_OWNER_START=""
RLCR_INFLIGHT_REVIEWER_STATE=""
RLCR_INFLIGHT_BOOT_ID=""
RLCR_CURRENT_BOOT_ID=""

# W4b action IDs are 64-hex SHA-256 values over the tagged, length-prefixed
# protocol record in rlcr-protocol.sh.  A reservation-* value may exist only
# while reviewer/convergence work is in flight; it is rebound before outbox or
# successor state publication.  The legacy gen-* form remains readable solely
# so W4a.5 crash fixtures can be fenced and retired safely.

rlcr_now_epoch() {
    date +%s
}

# Bind new inflight identities to this host boot.  Linux exposes a kernel boot
# UUID; macOS exposes kern.boottime.  The host component prevents a shared loop
# directory on another machine from treating the same boot-time text as local.
rlcr_boot_identity() {
    if [[ "$RLCR_CURRENT_BOOT_ID" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s\n' "$RLCR_CURRENT_BOOT_ID"
        return 0
    fi
    local boot_component="" host_component=""
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        IFS= read -r boot_component < /proc/sys/kernel/random/boot_id || return 1
        [[ "$boot_component" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
    elif command -v sysctl >/dev/null 2>&1; then
        boot_component=$(sysctl -n kern.boottime 2>/dev/null || true)
        [[ -n "$boot_component" ]] || return 1
    else
        return 1
    fi
    if [[ -r /etc/machine-id ]]; then
        IFS= read -r host_component < /etc/machine-id || true
    fi
    if [[ -z "$host_component" ]] && command -v sysctl >/dev/null 2>&1; then
        host_component=$(sysctl -n kern.hostuuid 2>/dev/null || true)
    fi
    [[ -n "$host_component" ]] || host_component=$(uname -n 2>/dev/null || true)
    [[ -n "$host_component" ]] || return 1
    RLCR_CURRENT_BOOT_ID=$(printf 'rlcr-boot-identity-v1\n%s\n%s\n' \
        "$host_component" "$boot_component" | rlcr_sha256_stream) || return 1
    [[ "$RLCR_CURRENT_BOOT_ID" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$RLCR_CURRENT_BOOT_ID"
}

rlcr_file_mtime() {
    local path="$1"
    stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null || echo 0
}

rlcr_new_token() {
    local random_part=""
    if [[ -r /dev/urandom ]]; then
        random_part=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    fi
    printf '%s_%s_%s\n' "$$" "$(rlcr_now_epoch)" "${random_part:-${RANDOM:-0}}"
}

rlcr_metadata_value() {
    local file="$1"
    local key="$2"
    local line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line; do
        if [[ "${line%%=*}" == "$key" ]]; then
            printf '%s\n' "${line#*=}"
            return 0
        fi
    done < "$file"
}

# Linux process identity used by the orphan-reviewer fence.  start_ticks is the
# kernel birth identity from /proc/<pid>/stat, so PID reuse cannot impersonate
# the persisted worker.  Output: process-group session start_ticks.
rlcr_proc_identity() {
    local pid="$1" stat_line stat_rest
    local -a stat_fields=()
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    stat_rest="${stat_line##*) }"
    read -r -a stat_fields <<< "$stat_rest"
    [[ ${#stat_fields[@]} -ge 20 ]] || return 1
    printf '%s %s %s\n' \
        "${stat_fields[2]}" "${stat_fields[3]}" "${stat_fields[19]}"
}

rlcr_process_matches_start() {
    local pid="$1" expected_start="$2"
    local process_group process_session actual_start
    [[ "$expected_start" =~ ^[0-9]+$ ]] || return 1
    read -r process_group process_session actual_start \
        < <(rlcr_proc_identity "$pid") || return 1
    [[ "$actual_start" == "$expected_start" ]]
}

rlcr_process_has_worker_id() {
    local pid="$1" worker_id="$2" entry
    [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ && -r "/proc/$pid/environ" ]] || return 1
    while IFS= read -r entry; do
        [[ "$entry" == "RLCR_REVIEWER_WORKER_ID=$worker_id" ]] && return 0
    done < <(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)
    return 1
}

# Kept as a function, rather than an environment override, so tests can supply
# a synthetic proc tree without making the production trust root configurable.
rlcr_proc_root() {
    printf '/proc\n'
}

# Tri-state process-group proof.  Return 0 for LIVE, 1 for EMPTY, and 4 for
# UNKNOWN.  A live member of the persisted session means the old reviewer can
# still write.  Zombies are already terminated and cannot touch the worktree.
# Any stat entry that remains present but cannot be inspected makes an empty
# result unprovable; callers must propagate status 4 rather than treating it as
# a false boolean.
rlcr_reviewer_group_live() {
    local wanted_pgid="$1" proc_root stat_file stat_line stat_rest
    local state process_group process_session
    local unknown=0 saw_group_member=0
    local -a stat_fields=()
    [[ "$wanted_pgid" =~ ^[1-9][0-9]*$ ]] || return 4
    # Persisted reviewer groups are created by this same uid.  A failed group
    # probe therefore proves that no signalable reviewer member remains and
    # avoids a full proc-table scan on every normal action commit.
    kill -0 -- "-$wanted_pgid" 2>/dev/null || return 1
    proc_root=$(rlcr_proc_root 2>/dev/null) || return 4
    [[ -d "$proc_root" ]] || return 4
    for stat_file in "$proc_root"/[0-9]*/stat; do
        [[ -e "$stat_file" || -L "$stat_file" ]] || continue
        if [[ ! -r "$stat_file" ]]; then
            unknown=1
            continue
        fi
        if ! IFS= read -r stat_line < "$stat_file"; then
            # A process that vanished between glob expansion and read cannot
            # remain in the group.  A still-present unreadable entry can.
            [[ ! -e "$stat_file" && ! -L "$stat_file" ]] || unknown=1
            continue
        fi
        if [[ "$stat_line" != *") "* ]]; then
            unknown=1
            continue
        fi
        stat_rest="${stat_line##*) }"
        stat_fields=()
        read -r -a stat_fields <<< "$stat_rest"
        if [[ ${#stat_fields[@]} -lt 4 ]]; then
            unknown=1
            continue
        fi
        state="${stat_fields[0]}"
        process_group="${stat_fields[2]}"
        process_session="${stat_fields[3]}"
        if [[ "$process_group" == "$wanted_pgid" && "$process_session" == "$wanted_pgid" ]]; then
            saw_group_member=1
            if [[ "$state" != "Z" && "$state" != "X" ]]; then
                return 0
            fi
        fi
    done

    [[ "$unknown" == "0" ]] || return 4
    # A positive group probe with no member in a complete proc snapshot is a
    # race or permission inconsistency, not proof of emptiness.  A snapshot
    # containing only zombie/dead members is mechanically EMPTY.
    if kill -0 -- "-$wanted_pgid" 2>/dev/null \
       && [[ "$saw_group_member" == "0" ]]; then
        return 4
    fi
    return 1
}

# Close the tiny prepare->fork->register window by finding the gated worker via
# its random inherited identity.  No start gate exists yet, so even a worker
# not scheduled in time for this scan cannot invoke Codex later.
rlcr_reviewer_prepared_pgid() {
    local worker_id="$1" environ_file pid process_group process_session _start_ticks
    for environ_file in /proc/[0-9]*/environ; do
        [[ -r "$environ_file" ]] || continue
        pid="${environ_file#/proc/}"
        pid="${pid%/environ}"
        rlcr_process_has_worker_id "$pid" "$worker_id" || continue
        read -r process_group process_session _start_ticks \
            < <(rlcr_proc_identity "$pid") || continue
        [[ "$process_group" == "$process_session" && "$process_group" =~ ^[1-9][0-9]*$ ]] \
            || return 1
        printf '%s\n' "$process_group"
        return 0
    done
    return 1
}

rlcr_lock_owner_write() {
    local lock_dir="$1"
    local token="$2"
    local now
    now=$(rlcr_now_epoch)
    local temp_file="$lock_dir/.owner.tmp.$$"
    {
        printf 'token=%s\n' "$token"
        printf 'pid=%s\n' "$$"
        printf 'heartbeat=%s\n' "$now"
    } > "$temp_file"
    mv "$temp_file" "$lock_dir/owner"
}

# Acquire a portable mkdir lease.  A contender claims stale-lock recovery by
# creating a token-specific directory inside the stale lock, revalidates the
# heartbeat, then atomically renames that exact lock directory out of the way.
# The owner token prevents a fenced-out process from releasing its successor.
rlcr_lock_acquire() {
    local scope_dir="$1"
    local wait_seconds="${2:-${RLCR_LOCK_WAIT_SECONDS:-30}}"
    local lease_seconds="${RLCR_LOCK_LEASE_SECONDS:-30}"
    local retry_seconds="${RLCR_LOCK_RETRY_SECONDS:-0.05}"
    local lock_dir="$scope_dir/.rlcr-control.lock"
    local token
    token=$(rlcr_new_token)
    local started now owner_file owner_token heartbeat age recovery stale_dir
    started=$(rlcr_now_epoch)

    [[ -d "$scope_dir" ]] || mkdir -p "$scope_dir"

    while :; do
        if mkdir "$lock_dir" 2>/dev/null; then
            rlcr_lock_owner_write "$lock_dir" "$token"
            RLCR_LOCK_TOKEN="$token"
            RLCR_LOCK_DIR="$lock_dir"
            return 0
        fi

        now=$(rlcr_now_epoch)
        owner_file="$lock_dir/owner"
        owner_token=$(rlcr_metadata_value "$owner_file" token)
        heartbeat=$(rlcr_metadata_value "$owner_file" heartbeat)
        if [[ ! "$heartbeat" =~ ^[0-9]+$ ]]; then
            heartbeat=$(rlcr_file_mtime "$lock_dir")
        fi
        [[ "$heartbeat" =~ ^[0-9]+$ ]] || heartbeat=0
        age=$((now - heartbeat))

        if [[ "$age" -gt "$lease_seconds" ]]; then
            # All contenders use the stale owner's token, so mkdir is an
            # O_EXCL-style CAS: only one can become the recovery writer.
            local safe_owner_token
            safe_owner_token=$(printf '%s' "${owner_token:-unknown}" | tr -cd 'A-Za-z0-9_.-')
            recovery="$lock_dir/.recover-${safe_owner_token:-unknown}"
            if mkdir "$recovery" 2>/dev/null; then
                # Revalidate after winning recovery.  An owner that refreshed
                # its heartbeat, or a replacement lock with another token,
                # must not be fenced out.
                local check_token check_heartbeat check_now
                check_token=$(rlcr_metadata_value "$owner_file" token)
                check_heartbeat=$(rlcr_metadata_value "$owner_file" heartbeat)
                check_now=$(rlcr_now_epoch)
                [[ "$check_heartbeat" =~ ^[0-9]+$ ]] || check_heartbeat=$(rlcr_file_mtime "$lock_dir")
                if [[ "${check_token:-}" == "${owner_token:-}" ]] \
                   && [[ "$check_heartbeat" =~ ^[0-9]+$ ]] \
                   && [[ $((check_now - check_heartbeat)) -gt "$lease_seconds" ]]; then
                    stale_dir="$scope_dir/.rlcr-control.lock.stale.$token"
                    if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
                        rm -rf "$stale_dir"
                    fi
                else
                    rmdir "$recovery" 2>/dev/null || true
                    # If the prior owner released while recovery was being
                    # revalidated, its rmdir was blocked by our CAS directory.
                    # Remove the now-empty shell lock instead of waiting a
                    # full additional lease; a live owner file makes this fail.
                    rmdir "$lock_dir" 2>/dev/null || true
                fi
            fi
        fi

        now=$(rlcr_now_epoch)
        if [[ $((now - started)) -ge "$wait_seconds" ]]; then
            echo "Error: timed out acquiring RLCR control lock: $lock_dir" >&2
            return 1
        fi
        sleep "$retry_seconds"
    done
}

rlcr_lock_heartbeat() {
    [[ -n "${RLCR_LOCK_DIR:-}" && -n "${RLCR_LOCK_TOKEN:-}" ]] || return 1
    local owner_file="$RLCR_LOCK_DIR/owner"
    local owner_token
    owner_token=$(rlcr_metadata_value "$owner_file" token)
    [[ "$owner_token" == "$RLCR_LOCK_TOKEN" ]] || return 1
    rlcr_lock_owner_write "$RLCR_LOCK_DIR" "$RLCR_LOCK_TOKEN"
}

rlcr_lock_release() {
    [[ -n "${RLCR_LOCK_DIR:-}" && -n "${RLCR_LOCK_TOKEN:-}" ]] || return 0
    local owner_file="$RLCR_LOCK_DIR/owner"
    local owner_token
    owner_token=$(rlcr_metadata_value "$owner_file" token)
    if [[ "$owner_token" == "$RLCR_LOCK_TOKEN" ]]; then
        rm -f "$owner_file"
        rmdir "$RLCR_LOCK_DIR" 2>/dev/null || true
    fi
    RLCR_LOCK_TOKEN=""
    RLCR_LOCK_DIR=""
}

rlcr_state_field_kind() {
    RLCR_STATE_FIELD_KIND=""
    case "$1" in
        current_round|max_iterations|codex_timeout|full_review_round|mainline_stall_count|control_epoch|closeout_steps|max_closeout_steps)
            RLCR_STATE_FIELD_KIND="uint" ;;
        plan_tracked|push_every_round|review_started|ask_codex_question|agent_teams|privacy_mode|bitlesson_required|bitlesson_allow_empty_none)
            RLCR_STATE_FIELD_KIND="bool" ;;
        codex_effort)
            RLCR_STATE_FIELD_KIND="effort" ;;
        last_mainline_verdict)
            RLCR_STATE_FIELD_KIND="verdict" ;;
        drift_status)
            RLCR_STATE_FIELD_KIND="drift" ;;
        codex_model|plan_file|start_branch|base_branch|base_commit|session_id|bitlesson_file|started_at|pending_action_id|pending_successor_phase|ack_action_id|ack_successor_phase|last_applied_action_id|last_convergence_digest|last_candidate_fingerprint|last_reducer_action)
            RLCR_STATE_FIELD_KIND="token" ;;
        pending_successor_generation|ack_successor_generation)
            RLCR_STATE_FIELD_KIND="optional_uint" ;;
        *)
            return 1 ;;
    esac
    printf '%s\n' "$RLCR_STATE_FIELD_KIND"
}

rlcr_validate_state_value() {
    local field="$1"
    local value="$2"
    local kind
    if ! rlcr_state_field_kind "$field" >/dev/null; then
        echo "Error: undeclared RLCR state field: $field" >&2
        return 1
    fi
    kind="$RLCR_STATE_FIELD_KIND"

    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* || "$value" == *' '* ]]; then
        echo "Error: unsafe whitespace in RLCR state value for $field" >&2
        return 1
    fi

    case "$kind" in
        uint) [[ "$value" =~ ^[0-9]+$ ]] ;;
        optional_uint) [[ -z "$value" || "$value" =~ ^[0-9]+$ ]] ;;
        bool) [[ "$value" == "true" || "$value" == "false" ]] ;;
        effort) [[ "$value" =~ ^(xhigh|high|medium|low)$ ]] ;;
        verdict) [[ "$value" =~ ^(advanced|stalled|regressed|unknown)$ ]] ;;
        drift) [[ "$value" =~ ^(normal|replan_required)$ ]] ;;
        token) [[ -z "$value" || "$value" =~ ^[A-Za-z0-9._/@:+-]+$ ]] ;;
        *) return 1 ;;
    esac || {
        echo "Error: invalid RLCR state value for $field: $value" >&2
        return 1
    }
}

rlcr_validate_state_document() {
    local state_file="$1"
    local field value
    while IFS=$'\t' read -r field value; do
        [[ -n "$field" ]] || continue
        rlcr_validate_state_value "$field" "$value" || return 1
    done < <(awk '
        BEGIN { section=0 }
        /^---$/ { section++; next }
        section == 1 && /^[A-Za-z_][A-Za-z0-9_]*:/ {
            key=$0; sub(/:.*/, "", key)
            value=$0; sub(/^[^:]*:[[:space:]]*/, "", value)
            print key "\t" value
        }
    ' "$state_file")
}

# Prepare, but do not publish, one structured state transition.  Assignments
# remain distinct argv entries; whitespace can never be re-split into fields.
rlcr_state_prepare() {
    local state_file="$1"
    local output_file="$2"
    shift 2
    [[ -f "$state_file" ]] || {
        echo "Error: RLCR state file not found: $state_file" >&2
        return 1
    }
    [[ $# -gt 0 ]] || {
        echo "Error: RLCR state transition requires at least one assignment" >&2
        return 1
    }
    local assignments_file="${output_file}.assignments"
    : > "$assignments_file"
    local assignment field value seen_fields=" "
    for assignment in "$@"; do
        [[ "$assignment" == *=* ]] || {
            echo "Error: malformed RLCR state assignment: $assignment" >&2
            rm -f "$assignments_file"
            return 1
        }
        field=${assignment%%=*}
        value=${assignment#*=}
        rlcr_validate_state_value "$field" "$value" || {
            rm -f "$assignments_file"
            return 1
        }
        case "$seen_fields" in
            *" $field "*)
                echo "Error: duplicate RLCR state assignment: $field" >&2
                rm -f "$assignments_file"
                return 1
                ;;
        esac
        seen_fields="$seen_fields$field "
        printf '%s\t%s\n' "$field" "$value" >> "$assignments_file"
    done

    awk -F '\t' '
        NR == FNR { values[$1]=$2; order[++count]=$1; next }
        {
            if ($0 == "---") {
                separators++
                if (separators == 2) {
                    for (i=1; i<=count; i++) {
                        key=order[i]
                        if (!(key in seen)) print key ": " values[key]
                    }
                }
                print
                next
            }
            if (separators == 1 && $0 ~ /^[A-Za-z_][A-Za-z0-9_]*:/) {
                key=$0; sub(/:.*/, "", key)
                if (key in values) {
                    if (!(key in seen)) print key ": " values[key]
                    seen[key]=1
                    next
                }
            }
            print
        }
        END { if (separators < 2) exit 42 }
    ' "$assignments_file" "$state_file" > "$output_file"
    local status=$?
    rm -f "$assignments_file"
    if [[ "$status" -ne 0 ]]; then
        rm -f "$output_file"
        echo "Error: malformed RLCR state document: $state_file" >&2
        return 1
    fi
}

rlcr_epoch_read() {
    local loop_dir="$1"
    local epoch=0
    if [[ -f "$loop_dir/.control-epoch" ]]; then
        epoch=$(sed -n '1p' "$loop_dir/.control-epoch" 2>/dev/null || echo 0)
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=0
    echo "$epoch"
}

rlcr_epoch_write_locked() {
    local loop_dir="$1"
    local epoch="$2"
    local temp_file="$loop_dir/.control-epoch.tmp.$$"
    printf '%s\n' "$epoch" > "$temp_file"
    mv "$temp_file" "$loop_dir/.control-epoch"
}

# Locked structured update used by non-action writers and compatibility calls.
rlcr_state_update() {
    local state_file="$1"
    shift
    local loop_dir scope_dir epoch next_epoch temp_file
    loop_dir=$(dirname "$state_file")
    scope_dir=$(dirname "$loop_dir")
    rlcr_lock_acquire "$scope_dir" || return 1
    if [[ -f "$loop_dir/.cancel-requested" || ! -f "$state_file" ]]; then
        rlcr_lock_release
        return 1
    fi
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    if [[ "$reviewer_fence_status" -ne 0 ]]; then
        rlcr_lock_release
        return 4
    fi
    epoch=$(rlcr_epoch_read "$loop_dir")
    next_epoch=$((epoch + 1))
    temp_file="${state_file}.txn.$$"
    if ! rlcr_state_prepare "$state_file" "$temp_file" "$@" "control_epoch=$next_epoch"; then
        rlcr_lock_release
        return 1
    fi
    if ! rlcr_lock_heartbeat; then
        rm -f "$temp_file"
        rlcr_lock_release
        return 2
    fi
    rlcr_epoch_write_locked "$loop_dir" "$next_epoch"
    mv "$temp_file" "$state_file"
    rlcr_lock_release
}

rlcr_active_state_file() {
    local loop_dir="$1"
    if [[ -f "$loop_dir/methodology-analysis-state.md" ]]; then
        echo "$loop_dir/methodology-analysis-state.md"
    elif [[ -f "$loop_dir/finalize-state.md" ]]; then
        echo "$loop_dir/finalize-state.md"
    elif [[ -f "$loop_dir/state.md" ]]; then
        echo "$loop_dir/state.md"
    fi
}

rlcr_state_field_value() {
    local state_file="$1" field="$2"
    sed -n "s/^${field}:[[:space:]]*//p" "$state_file" 2>/dev/null | head -1
}

# Phase remains encoded by the established state filename protocol.  state.md
# additionally distinguishes implementation from review using review_started.
rlcr_state_phase() {
    local state_path="$1" content_file="${2:-$1}" base
    base=$(basename "$state_path")
    case "$base" in
        state.md)
            if [[ "$(rlcr_state_field_value "$content_file" review_started)" == "true" ]]; then
                echo review
            else
                echo impl
            fi
            ;;
        methodology-analysis-state.md) echo methodology ;;
        finalize-state.md) echo finalize ;;
        *-state.md) echo "terminal-${base%-state.md}" ;;
        *) return 1 ;;
    esac
}

# Snapshot the generation/phase visible when this hook invocation begins.
# A publisher that was already in flight before an action commit observes the
# predecessor tuple and may replay, but can never acknowledge the successor.
rlcr_observe_successor() {
    local loop_dir="$1" state_file=""
    RLCR_OBSERVED_GENERATION=$(rlcr_epoch_read "$loop_dir")
    state_file=$(rlcr_active_state_file "$loop_dir")
    if [[ -z "$state_file" ]]; then
        local target
        target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
        [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] && state_file="$loop_dir/$target"
    fi
    if [[ -n "$state_file" && -f "$state_file" ]]; then
        RLCR_OBSERVED_PHASE=$(rlcr_state_phase "$state_file" 2>/dev/null || true)
    else
        RLCR_OBSERVED_PHASE=""
    fi
}

rlcr_action_delivery_clear_locked() {
    local loop_dir="$1"
    rm -f "$loop_dir/.decision-outbox.json" \
          "$loop_dir/.decision-delivered" \
          "$loop_dir/.decision-claim" \
          "$loop_dir/.pending-action-id" \
          "$loop_dir/.pending-action-epoch" \
          "$loop_dir/.pending-successor-generation" \
          "$loop_dir/.pending-successor-phase" \
          "$loop_dir/.pending-action-kind" \
          "$loop_dir/.pending-action-target"
}

# Sidecars are intentionally published before the committing state rename.
# Therefore recovery must prove the rename happened from the committed file,
# not merely from an epoch/outbox that may have been left by a killed writer.
rlcr_pending_action_is_committed() {
    local loop_dir="$1" action_id="$2"
    local kind target target_file applied_id pending_id
    kind=$(sed -n '1p' "$loop_dir/.pending-action-kind" 2>/dev/null || true)
    target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
    [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    target_file="$loop_dir/$target"
    [[ -f "$target_file" ]] || return 1
    pending_id=$(rlcr_state_field_value "$target_file" pending_action_id)
    case "$kind" in
        same-state)
            applied_id=$(rlcr_state_field_value "$target_file" last_applied_action_id)
            [[ "$pending_id" == "$action_id" || "$applied_id" == "$action_id" ]]
            ;;
        phase)
            # The successor state itself, rather than only sidecar metadata,
            # must name its predecessor action.
            [[ "$pending_id" == "$action_id" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

rlcr_action_ack_is_committed() {
    local loop_dir="$1" action_id="$2" generation="$3" phase="$4"
    local target target_file
    target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
    [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    target_file="$loop_dir/$target"
    [[ -f "$target_file" ]] || return 1
    [[ "$(rlcr_state_field_value "$target_file" ack_action_id)" == "$action_id" \
       && "$(rlcr_state_field_value "$target_file" ack_successor_generation)" == "$generation" \
       && "$(rlcr_state_field_value "$target_file" ack_successor_phase)" == "$phase" ]]
}

rlcr_action_ack_finalize_locked() {
    local loop_dir="$1" target state_file ack_epoch reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    [[ "$reviewer_fence_status" -eq 0 ]] || return 4
    target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
    if [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]]; then
        state_file="$loop_dir/$target"
        ack_epoch=$(rlcr_state_field_value "$state_file" control_epoch)
        [[ "$ack_epoch" =~ ^[0-9]+$ ]] && rlcr_epoch_write_locked "$loop_dir" "$ack_epoch"
    fi
    rlcr_action_delivery_clear_locked "$loop_dir"
}

rlcr_successor_binds_action() {
    local loop_dir="$1" action_id="$2" generation="$3" phase="$4"
    local target target_file
    target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
    [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    target_file="$loop_dir/$target"
    [[ -f "$target_file" ]] || return 1
    [[ "$(rlcr_state_field_value "$target_file" pending_action_id)" == "$action_id" \
       && "$(rlcr_state_field_value "$target_file" pending_successor_generation)" == "$generation" \
       && "$(rlcr_state_field_value "$target_file" pending_successor_phase)" == "$phase" ]]
}

rlcr_action_is_delivered() {
    local loop_dir="$1" action_id="$2"
    [[ "$(sed -n '1p' "$loop_dir/.decision-delivered" 2>/dev/null || true)" == "$action_id" ]]
}

rlcr_find_pending_action_loop() {
    local loop_base_dir="$1" session_id="${2:-}"
    local dir target state_file recorded_session
    [[ -d "$loop_base_dir" ]] || return 1
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        dir="${dir%/}"
        [[ -s "$dir/.pending-action-id" && -s "$dir/.decision-outbox.json" ]] || continue
        target=$(sed -n '1p' "$dir/.pending-action-target" 2>/dev/null || true)
        [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || continue
        state_file="$dir/$target"
        [[ -f "$state_file" ]] || continue
        if [[ -n "$session_id" ]]; then
            recorded_session=$(sed -n 's/^session_id:[[:space:]]*//p' "$state_file" 2>/dev/null | head -1)
            [[ -z "$recorded_session" || "$recorded_session" == "$session_id" ]] || continue
        fi
        printf '%s\n' "$dir"
        return 0
    done < <(ls -1d "$loop_base_dir"/*/ 2>/dev/null | sort -r)
    return 1
}

# Recover an already committed action before normal hook phase/schema guards.
# Returns 2 when the caller must replay RLCR_ACTION_ID, 3 when canceled, and 1
# when there is no pending delivery (including a successor acknowledgement).
rlcr_action_recover_pending() {
    local scope_dir="$1" loop_dir="$2"
    local observed_generation="${3:-${RLCR_OBSERVED_GENERATION:-}}"
    local observed_phase="${4:-${RLCR_OBSERVED_PHASE:-}}"
    rlcr_lock_acquire "$scope_dir" || return 1
    if [[ -f "$loop_dir/.cancel-requested" ]]; then
        rlcr_lock_release
        return 3
    fi
    if [[ ! -s "$loop_dir/.pending-action-id" || ! -s "$loop_dir/.decision-outbox.json" ]]; then
        rlcr_lock_release
        return 1
    fi

    local action_id pending_epoch current_epoch successor_generation successor_phase
    action_id=$(sed -n '1p' "$loop_dir/.pending-action-id")
    pending_epoch=$(sed -n '1p' "$loop_dir/.pending-action-epoch" 2>/dev/null || true)
    successor_generation=$(sed -n '1p' "$loop_dir/.pending-successor-generation" 2>/dev/null || true)
    successor_phase=$(sed -n '1p' "$loop_dir/.pending-successor-phase" 2>/dev/null || true)
    current_epoch=$(rlcr_epoch_read "$loop_dir")
    if rlcr_action_ack_is_committed "$loop_dir" "$action_id" \
        "$successor_generation" "$successor_phase"; then
        local finalize_status=0
        rlcr_action_ack_finalize_locked "$loop_dir" || finalize_status=$?
        rlcr_lock_release
        [[ "$finalize_status" -eq 0 ]] || return 4
        return 1
    fi
    if [[ ! "$pending_epoch" =~ ^[0-9]+$ \
       || ! "$successor_generation" =~ ^[0-9]+$ \
       || -z "$successor_phase" ]] \
       || [[ "$pending_epoch" -gt "$current_epoch" ]] \
       || ! rlcr_pending_action_is_committed "$loop_dir" "$action_id"; then
        rlcr_action_delivery_clear_locked "$loop_dir"
        rlcr_lock_release
        return 1
    fi

    if rlcr_action_is_delivered "$loop_dir" "$action_id" \
       && [[ "$observed_generation" == "$successor_generation" \
       && "$observed_phase" == "$successor_phase" ]] \
       && rlcr_successor_binds_action "$loop_dir" "$action_id" \
            "$successor_generation" "$successor_phase"; then
            local ack_status=0
            rlcr_action_ack_locked "$loop_dir" "$action_id" \
                "$successor_generation" "$successor_phase" || ack_status=$?
            if [[ "$ack_status" -ne 0 ]]; then
                rlcr_lock_release
                [[ "$ack_status" -eq 4 ]] && return 4
                return 1
            fi
            rlcr_lock_release
            return 1
    fi

    RLCR_ACTION_ID="$action_id"
    RLCR_ACTION_EPOCH="$pending_epoch"
    RLCR_ACTION_MODE="replay"
    rlcr_lock_release
    return 2
}

rlcr_pending_signal_targets_loop() {
    local signal_file="$1"
    local loop_dir="$2"
    local target=""
    [[ -f "$signal_file" ]] || return 1
    IFS= read -r target < "$signal_file" || true
    [[ "$target" == "$loop_dir/"* ]]
}

# Shared cancel transaction for both CLI implementations.  All sidecars are
# changed before the active-state rename, which is the sole commit point.
rlcr_cancel_transaction() {
    local scope_dir="$1"
    local loop_dir="$2"
    local pending_signal="$3"
    rlcr_lock_acquire "$scope_dir" || return 1
    local active_state
    active_state=$(rlcr_active_state_file "$loop_dir")
    if [[ -z "$active_state" ]]; then
        if [[ -f "$loop_dir/cancel-state.md" ]]; then
            rlcr_lock_release
            return 0
        fi
        rlcr_lock_release
        return 1
    fi

    if ! rlcr_lock_heartbeat; then
        rlcr_lock_release
        return 2
    fi
    local cancel_temp="$loop_dir/.cancel-requested.tmp.$$"
    printf 'requested_at=%s\n' "$(rlcr_now_epoch)" > "$cancel_temp"
    mv "$cancel_temp" "$loop_dir/.cancel-requested"
    if rlcr_pending_signal_targets_loop "$pending_signal" "$loop_dir" \
       || rlcr_pending_signal_targets_loop "${pending_signal}.claimed" "$loop_dir"; then
        rm -f "$pending_signal" "${pending_signal}.claimed"
    fi
    local reviewer_terminate_status=0
    rlcr_reviewer_terminate_locked "$loop_dir" || reviewer_terminate_status=$?
    if [[ "$reviewer_terminate_status" -ne 0 ]]; then
        echo "Error: refusing cancellation until the active reviewer identity can be terminated" >&2
        rlcr_lock_release
        return 4
    fi
    rm -f "$loop_dir/.methodology-exit-reason" "$loop_dir/.action-inflight"
    rlcr_action_delivery_clear_locked "$loop_dir"
    local epoch
    epoch=$(rlcr_epoch_read "$loop_dir")
    rlcr_epoch_write_locked "$loop_dir" "$((epoch + 1))"
    mv "$active_state" "$loop_dir/cancel-state.md"
    rlcr_lock_release
}

rlcr_inflight_write_locked() {
    local loop_dir="$1" action_id="$2" epoch="$3"
    local _hook_process_group="" _hook_session="" hook_start_ticks="" boot_identity=""
    read -r _hook_process_group _hook_session hook_start_ticks \
        < <(rlcr_proc_identity "$$" 2>/dev/null || true)
    rlcr_boot_identity >/dev/null || return 1
    boot_identity="$RLCR_CURRENT_BOOT_ID"
    local temp_file="$loop_dir/.action-inflight.tmp.$$"
    {
        printf 'action_id=%s\n' "$action_id"
        printf 'epoch=%s\n' "$epoch"
        printf 'pid=%s\n' "$$"
        printf 'hook_start_ticks=%s\n' "$hook_start_ticks"
        printf 'boot_identity=%s\n' "$boot_identity"
        printf 'started=%s\n' "$(rlcr_now_epoch)"
        printf 'reviewer_protocol=pgid-v1\n'
        printf 'reviewer_state=none\n'
    } > "$temp_file"
    mv "$temp_file" "$loop_dir/.action-inflight"
}

rlcr_inflight_owned_by_current_hook() {
    local inflight_file="$1" owner_pid owner_start owner_boot current_boot
    local _current_group _current_session current_start
    owner_pid=$(rlcr_metadata_value "$inflight_file" pid)
    owner_start=$(rlcr_metadata_value "$inflight_file" hook_start_ticks)
    owner_boot=$(rlcr_metadata_value "$inflight_file" boot_identity)
    [[ "$owner_pid" == "$$" ]] || return 1
    if [[ -n "$owner_boot" ]]; then
        rlcr_boot_identity >/dev/null || return 1
        current_boot="$RLCR_CURRENT_BOOT_ID"
        [[ "$owner_boot" == "$current_boot" ]] || return 1
    fi
    if read -r _current_group _current_session current_start \
        < <(rlcr_proc_identity "$$" 2>/dev/null); then
        [[ "$owner_start" == "$current_start" ]]
    else
        # The reviewer itself is disabled without /proc; retain the historical
        # same-PID fence for non-reviewer decisions on unsupported platforms.
        [[ -z "$owner_start" ]]
    fi
}

rlcr_inflight_reviewer_write_locked() {
    local loop_dir="$1" reviewer_state="$2" worker_id="${3:-}"
    local reviewer_pid="${4:-}" reviewer_pgid="${5:-}" reviewer_start_ticks="${6:-}"
    local inflight_file="$loop_dir/.action-inflight" temp_file
    local action_id epoch owner_pid hook_start_ticks boot_identity started protocol
    action_id=$(rlcr_metadata_value "$inflight_file" action_id)
    epoch=$(rlcr_metadata_value "$inflight_file" epoch)
    owner_pid=$(rlcr_metadata_value "$inflight_file" pid)
    hook_start_ticks=$(rlcr_metadata_value "$inflight_file" hook_start_ticks)
    boot_identity=$(rlcr_metadata_value "$inflight_file" boot_identity)
    started=$(rlcr_metadata_value "$inflight_file" started)
    protocol=$(rlcr_metadata_value "$inflight_file" reviewer_protocol)
    [[ -n "$action_id" && "$epoch" =~ ^[0-9]+$ && "$owner_pid" =~ ^[0-9]+$ \
       && "$boot_identity" =~ ^[0-9a-f]{64}$ \
       && "$started" =~ ^[0-9]+$ && "$protocol" == "pgid-v1" ]] || return 1
    temp_file="$loop_dir/.action-inflight.tmp.$$"
    {
        printf 'action_id=%s\n' "$action_id"
        printf 'epoch=%s\n' "$epoch"
        printf 'pid=%s\n' "$owner_pid"
        printf 'hook_start_ticks=%s\n' "$hook_start_ticks"
        printf 'boot_identity=%s\n' "$boot_identity"
        printf 'started=%s\n' "$started"
        printf 'reviewer_protocol=pgid-v1\n'
        printf 'reviewer_state=%s\n' "$reviewer_state"
        [[ -z "$worker_id" ]] || printf 'reviewer_worker_id=%s\n' "$worker_id"
        [[ -z "$reviewer_pid" ]] || printf 'reviewer_pid=%s\n' "$reviewer_pid"
        [[ -z "$reviewer_pgid" ]] || printf 'reviewer_pgid=%s\n' "$reviewer_pgid"
        [[ -z "$reviewer_start_ticks" ]] \
            || printf 'reviewer_start_ticks=%s\n' "$reviewer_start_ticks"
    } > "$temp_file"
    mv "$temp_file" "$inflight_file"
}

rlcr_inflight_record_valid() {
    local inflight_file="$1"
    local action_id epoch owner_pid hook_start_ticks boot_identity started protocol reviewer_state
    local worker_id reviewer_pid reviewer_pgid reviewer_start_ticks
    local line key value seen_keys=" "
    action_id=""; epoch=""; owner_pid=""; hook_start_ticks=""; boot_identity=""; started=""
    protocol=""; reviewer_state=""; worker_id=""; reviewer_pid=""
    reviewer_pgid=""; reviewer_start_ticks=""
    [[ -f "$inflight_file" ]] || return 1
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || return 1
        key="${line%%=*}"
        value="${line#*=}"
        case "$seen_keys" in *" $key "*) return 1 ;; esac
        seen_keys="$seen_keys$key "
        case "$key" in
            action_id) action_id="$value" ;;
            epoch) epoch="$value" ;;
            pid) owner_pid="$value" ;;
            hook_start_ticks) hook_start_ticks="$value" ;;
            boot_identity) boot_identity="$value" ;;
            started) started="$value" ;;
            reviewer_protocol) protocol="$value" ;;
            reviewer_state) reviewer_state="$value" ;;
            reviewer_worker_id) worker_id="$value" ;;
            reviewer_pid) reviewer_pid="$value" ;;
            reviewer_pgid) reviewer_pgid="$value" ;;
            reviewer_start_ticks) reviewer_start_ticks="$value" ;;
            *) return 1 ;;
        esac
    done < "$inflight_file"

    [[ "$action_id" =~ ^(gen-[0-9]+-(impl|review)-[0-9]+|reservation-[0-9a-f]{64}|[0-9a-f]{64})$ \
       && "$epoch" =~ ^[0-9]+$ && "$owner_pid" =~ ^[1-9][0-9]*$ \
       && "$hook_start_ticks" =~ ^[0-9]*$ && "$started" =~ ^[0-9]+$ \
       && "$protocol" == "pgid-v1" ]] || return 1
    local current_boot_identity=""
    if [[ "$action_id" == reservation-* || "$action_id" =~ ^[0-9a-f]{64}$ ]]; then
        [[ "$boot_identity" =~ ^[0-9a-f]{64}$ ]] || return 1
        rlcr_boot_identity >/dev/null || return 1
        current_boot_identity="$RLCR_CURRENT_BOOT_ID"
        [[ "$boot_identity" == "$current_boot_identity" ]] || return 1
    elif [[ -n "$boot_identity" ]]; then
        [[ "$boot_identity" =~ ^[0-9a-f]{64}$ ]] || return 1
        rlcr_boot_identity >/dev/null || return 1
        current_boot_identity="$RLCR_CURRENT_BOOT_ID"
        [[ "$boot_identity" == "$current_boot_identity" ]] || return 1
    fi
    RLCR_INFLIGHT_OWNER_PID="$owner_pid"
    RLCR_INFLIGHT_OWNER_START="$hook_start_ticks"
    RLCR_INFLIGHT_REVIEWER_STATE="$reviewer_state"
    RLCR_INFLIGHT_BOOT_ID="$boot_identity"
    case "$reviewer_state" in
        none)
            [[ -z "$worker_id" && -z "$reviewer_pid" && -z "$reviewer_pgid" \
               && -z "$reviewer_start_ticks" ]]
            ;;
        prepared)
            [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ && -z "$reviewer_pid" \
               && -z "$reviewer_pgid" && -z "$reviewer_start_ticks" ]]
            ;;
        registered)
            [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ \
               && "$reviewer_pid" =~ ^[1-9][0-9]*$ \
               && "$reviewer_pgid" =~ ^[1-9][0-9]*$ \
               && "$reviewer_start_ticks" =~ ^[0-9]+$ ]]
            ;;
        finished)
            [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
            if [[ -z "$reviewer_pid" && -z "$reviewer_pgid" \
               && -z "$reviewer_start_ticks" ]]; then
                return 0
            fi
            [[ "$reviewer_pid" =~ ^[1-9][0-9]*$ \
               && "$reviewer_pgid" =~ ^[1-9][0-9]*$ \
               && "$reviewer_start_ticks" =~ ^[0-9]+$ ]]
            ;;
        *) return 1 ;;
    esac
}

# This function is called with the control lock held.  It does not return
# success until /proc proves that no non-zombie member remains in the old
# reviewer's persisted session/process group.
rlcr_reviewer_terminate_locked() {
    local loop_dir="$1" inflight_file
    inflight_file="$loop_dir/.action-inflight"
    [[ -f "$inflight_file" ]] || return 0
    rlcr_inflight_record_valid "$inflight_file" || {
        echo "Error: malformed inflight reviewer metadata; recovery fenced" >&2
        return 4
    }
    local protocol reviewer_state worker_id reviewer_pid reviewer_pgid reviewer_start_ticks
    protocol=$(rlcr_metadata_value "$inflight_file" reviewer_protocol)
    reviewer_state=$(rlcr_metadata_value "$inflight_file" reviewer_state)
    worker_id=$(rlcr_metadata_value "$inflight_file" reviewer_worker_id)
    reviewer_pid=$(rlcr_metadata_value "$inflight_file" reviewer_pid)
    reviewer_pgid=$(rlcr_metadata_value "$inflight_file" reviewer_pgid)
    reviewer_start_ticks=$(rlcr_metadata_value "$inflight_file" reviewer_start_ticks)

    [[ "$protocol" == "pgid-v1" ]] || {
        echo "Error: legacy inflight action has no mechanically recoverable reviewer identity" >&2
        return 1
    }
    case "$reviewer_state" in
        none) return 0 ;;
        prepared|registered|finished) ;;
        *) echo "Error: invalid inflight reviewer state: $reviewer_state" >&2; return 1 ;;
    esac
    [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1

    if [[ "$reviewer_state" == "prepared" && -z "$reviewer_pgid" ]]; then
        reviewer_pgid=$(rlcr_reviewer_prepared_pgid "$worker_id" 2>/dev/null || true)
        # No identity-bearing process plus an unpublished per-worker gate is a
        # mechanical proof that no old Codex payload can have started.
        [[ -n "$reviewer_pgid" ]] || return 0
    fi
    [[ "$reviewer_pid" =~ ^[0-9]*$ && "$reviewer_pgid" =~ ^[1-9][0-9]*$ \
       && "$reviewer_start_ticks" =~ ^[0-9]*$ ]] || return 1

    if [[ -n "$reviewer_pid" && -n "$reviewer_start_ticks" ]] \
       && rlcr_process_matches_start "$reviewer_pid" "$reviewer_start_ticks"; then
        local current_pgid current_session current_start
        read -r current_pgid current_session current_start \
            < <(rlcr_proc_identity "$reviewer_pid") || return 1
        [[ "$current_pgid" == "$reviewer_pgid" && "$current_session" == "$reviewer_pgid" ]] \
            || return 1
        rlcr_process_has_worker_id "$reviewer_pid" "$worker_id" || return 1
    fi

    local group_state=0
    rlcr_reviewer_group_live "$reviewer_pgid" || group_state=$?
    case "$group_state" in
        0) ;;
        1) return 0 ;;
        *)
            echo "Error: reviewer process group $reviewer_pgid cannot be proven empty" >&2
            return 4
            ;;
    esac
    kill -TERM -- "-$reviewer_pgid" 2>/dev/null || true
    local wait_tick=0
    while [[ "$wait_tick" -lt 40 ]]; do
        sleep 0.05
        wait_tick=$((wait_tick + 1))
        group_state=0
        rlcr_reviewer_group_live "$reviewer_pgid" || group_state=$?
        case "$group_state" in
            0) ;;
            1) return 0 ;;
            *)
                echo "Error: reviewer process group $reviewer_pgid became uninspectable" >&2
                return 4
                ;;
        esac
    done
    kill -KILL -- "-$reviewer_pgid" 2>/dev/null || true
    wait_tick=0
    while [[ "$wait_tick" -lt 100 ]]; do
        sleep 0.05
        wait_tick=$((wait_tick + 1))
        group_state=0
        rlcr_reviewer_group_live "$reviewer_pgid" || group_state=$?
        case "$group_state" in
            0) ;;
            1) return 0 ;;
            *)
                echo "Error: reviewer process group $reviewer_pgid became uninspectable" >&2
                return 4
                ;;
        esac
    done
    echo "Error: old reviewer process group $reviewer_pgid is still live; recovery fenced" >&2
    return 4
}

# All epoch/phase writers call this with the project-wide control
# lock held.  An inflight reservation may be removed only after the reviewer
# group is mechanically EMPTY.  Malformed metadata and UNKNOWN proc scans both
# map to the public fail-closed status 4.
rlcr_epoch_writer_fence_locked() {
    local loop_dir="$1" terminate_status=0 inflight_file reviewer_state
    local owner_pid owner_start _owner_group _owner_session actual_owner_start
    [[ -f "$loop_dir/.action-inflight" ]] || return 0
    inflight_file="$loop_dir/.action-inflight"
    rlcr_inflight_record_valid "$inflight_file" || return 4
    owner_pid="$RLCR_INFLIGHT_OWNER_PID"
    owner_start="$RLCR_INFLIGHT_OWNER_START"
    reviewer_state="$RLCR_INFLIGHT_REVIEWER_STATE"
    # A different live hook could still advance none->prepared->fork after our
    # instantaneous group scan.  It must remain the sole writer until it exits;
    # only its own commit may consume its reservation.  PID reuse is separated
    # by start_ticks, and an uninspectable live owner is UNKNOWN/status 4.
    if [[ "$owner_pid" != "$$" ]] && kill -0 "$owner_pid" 2>/dev/null; then
        [[ "$owner_start" =~ ^[0-9]+$ ]] || return 4
        read -r _owner_group _owner_session actual_owner_start \
            < <(rlcr_proc_identity "$owner_pid" 2>/dev/null) || return 4
        [[ "$actual_owner_start" != "$owner_start" ]] || return 4
    fi
    # `finished` is itself a durable empty-group proof: it is published only
    # by rlcr_reviewer_finish after waiting for the worker and running the
    # termination proof under this same lock.  A dead process group cannot be
    # resurrected, so epoch commits need not rescan the entire proc table.
    if [[ "$reviewer_state" == "finished" ]]; then
        rm -f "$inflight_file"
        return 0
    fi
    rlcr_reviewer_terminate_locked "$loop_dir" || terminate_status=$?
    [[ "$terminate_status" -eq 0 ]] || return 4
    rm -f "$inflight_file"
}

rlcr_reviewer_prepare() {
    local scope_dir="$1" loop_dir="$2" action_id="$3" expected_epoch="$4" worker_id="$5"
    [[ "$worker_id" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    rlcr_lock_acquire "$scope_dir" || return 1
    local inflight_file="$loop_dir/.action-inflight"
    if [[ "$(rlcr_metadata_value "$inflight_file" action_id)" != "$action_id" \
       || "$(rlcr_metadata_value "$inflight_file" epoch)" != "$expected_epoch" \
       || "$(rlcr_metadata_value "$inflight_file" reviewer_state)" != "none" ]] \
       || ! rlcr_inflight_owned_by_current_hook "$inflight_file" \
       || ! rlcr_inflight_reviewer_write_locked "$loop_dir" prepared "$worker_id"; then
        rlcr_lock_release
        return 1
    fi
    rlcr_lock_release
}

rlcr_reviewer_register() {
    local scope_dir="$1" loop_dir="$2" action_id="$3" expected_epoch="$4"
    local worker_id="$5" worker_pid="$6" worker_pgid="$7" worker_start_ticks="$8"
    local actual_pgid actual_session actual_start
    read -r actual_pgid actual_session actual_start \
        < <(rlcr_proc_identity "$worker_pid") || return 1
    [[ "$actual_pgid" == "$worker_pgid" && "$actual_session" == "$worker_pgid" \
       && "$actual_start" == "$worker_start_ticks" && "$worker_pid" == "$worker_pgid" ]] \
       || return 1
    rlcr_process_has_worker_id "$worker_pid" "$worker_id" || return 1

    rlcr_lock_acquire "$scope_dir" || return 1
    local inflight_file="$loop_dir/.action-inflight"
    if [[ "$(rlcr_metadata_value "$inflight_file" action_id)" != "$action_id" \
       || "$(rlcr_metadata_value "$inflight_file" epoch)" != "$expected_epoch" \
       || "$(rlcr_metadata_value "$inflight_file" reviewer_state)" != "prepared" \
       || "$(rlcr_metadata_value "$inflight_file" reviewer_worker_id)" != "$worker_id" ]] \
       || ! rlcr_inflight_owned_by_current_hook "$inflight_file" \
       || ! rlcr_inflight_reviewer_write_locked "$loop_dir" registered \
            "$worker_id" "$worker_pid" "$worker_pgid" "$worker_start_ticks"; then
        rlcr_lock_release
        return 1
    fi
    rlcr_lock_release
}

rlcr_reviewer_finish() {
    local scope_dir="$1" loop_dir="$2" action_id="$3" expected_epoch="$4" worker_id="$5"
    rlcr_lock_acquire "$scope_dir" || return 1
    local inflight_file="$loop_dir/.action-inflight" state reviewer_pid reviewer_pgid reviewer_start_ticks
    state=$(rlcr_metadata_value "$inflight_file" reviewer_state)
    if [[ "$(rlcr_metadata_value "$inflight_file" action_id)" != "$action_id" \
       || "$(rlcr_metadata_value "$inflight_file" epoch)" != "$expected_epoch" \
       || "$(rlcr_metadata_value "$inflight_file" reviewer_worker_id)" != "$worker_id" \
       || ! "$state" =~ ^(prepared|registered)$ ]] \
       || ! rlcr_inflight_owned_by_current_hook "$inflight_file" \
       || ! rlcr_reviewer_terminate_locked "$loop_dir"; then
        rlcr_lock_release
        return 1
    fi
    reviewer_pid=$(rlcr_metadata_value "$inflight_file" reviewer_pid)
    reviewer_pgid=$(rlcr_metadata_value "$inflight_file" reviewer_pgid)
    reviewer_start_ticks=$(rlcr_metadata_value "$inflight_file" reviewer_start_ticks)
    if ! rlcr_inflight_reviewer_write_locked "$loop_dir" finished \
        "$worker_id" "$reviewer_pid" "$reviewer_pgid" "$reviewer_start_ticks"; then
        rlcr_lock_release
        return 1
    fi
    rlcr_lock_release
}

rlcr_publish_action_sidecars_locked() {
    local manifest="${RLCR_ACTION_SIDECAR_MANIFEST:-}"
    [[ -n "$manifest" && -f "$manifest" ]] || return 0
    local source_path target_path
    while IFS=$'\t' read -r source_path target_path; do
        [[ -n "$source_path" && -n "$target_path" ]] || continue
        [[ -f "$source_path" ]] || {
            echo "Error: prepared RLCR sidecar missing: $source_path" >&2
            return 1
        }
        mv "$source_path" "$target_path"
    done < "$manifest"
}

rlcr_action_ack_locked() {
    local loop_dir="$1" action_id="$2" successor_generation="$3" successor_phase="$4"
    local state_file target epoch next_epoch temp_file claim_file claim_temp
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    [[ "$reviewer_fence_status" -eq 0 ]] || return 4
    target=$(sed -n '1p' "$loop_dir/.pending-action-target" 2>/dev/null || true)
    [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    state_file="$loop_dir/$target"
    [[ -f "$state_file" ]] || return 1
    [[ "$(sed -n '1p' "$loop_dir/.pending-action-id" 2>/dev/null || true)" == "$action_id" \
       && "$(sed -n '1p' "$loop_dir/.pending-successor-generation" 2>/dev/null || true)" == "$successor_generation" \
       && "$(sed -n '1p' "$loop_dir/.pending-successor-phase" 2>/dev/null || true)" == "$successor_phase" ]] || return 1
    rlcr_action_is_delivered "$loop_dir" "$action_id" || return 1
    rlcr_successor_binds_action "$loop_dir" "$action_id" \
        "$successor_generation" "$successor_phase" || return 1

    epoch=$(rlcr_epoch_read "$loop_dir")
    next_epoch=$((epoch + 1))
    rlcr_lock_heartbeat || return 1

    # The claim is a recoverable consumer-side intent record.  It is bound to
    # the complete ack tuple and never inferred from wall-clock ordering.
    claim_file="$loop_dir/.decision-claim"
    if [[ -f "$claim_file" ]]; then
        [[ "$(rlcr_metadata_value "$claim_file" action_id)" == "$action_id" \
           && "$(rlcr_metadata_value "$claim_file" successor_generation)" == "$successor_generation" \
           && "$(rlcr_metadata_value "$claim_file" successor_phase)" == "$successor_phase" ]] \
           || return 1
    else
        claim_temp="${claim_file}.tmp.$$"
        {
            printf 'action_id=%s\n' "$action_id"
            printf 'successor_generation=%s\n' "$successor_generation"
            printf 'successor_phase=%s\n' "$successor_phase"
        } > "$claim_temp"
        mv "$claim_temp" "$claim_file"
    fi
    if [[ "${RLCR_TEST_KILL_AFTER_CONSUMER_CLAIM:-}" == "1" ]]; then
        kill -9 "$$"
    fi

    temp_file="${state_file}.ack.$$"
    if ! rlcr_state_prepare "$state_file" "$temp_file" \
        "pending_action_id=" \
        "pending_successor_generation=" \
        "pending_successor_phase=" \
        "ack_action_id=$action_id" \
        "ack_successor_generation=$successor_generation" \
        "ack_successor_phase=$successor_phase" \
        "last_applied_action_id=$action_id" \
        "control_epoch=$next_epoch"; then
        rm -f "$temp_file"
        return 1
    fi
    mv "$temp_file" "$state_file"
    if [[ "${RLCR_TEST_KILL_AFTER_ACK_COMMIT:-}" == "1" ]]; then
        kill -9 "$$"
    fi
    rlcr_epoch_write_locked "$loop_dir" "$next_epoch"
    rlcr_action_delivery_clear_locked "$loop_dir"
}

# Reserve one generation.  Concurrent gate/native-Stop publishers wait for and
# replay the same canonical outbox action.  A dead publisher can be replaced
# without changing action_id; Codex still runs outside the control lock.
# Returns: 0 leader, 2 replay canonical action, 3 canceled/no active loop,
# 4 fail-closed because the prior writer/reviewer cannot be proven terminated.
rlcr_action_begin() {
    local scope_dir="$1" loop_dir="$2" phase="$3" round="$4"
    local retry_seconds="${RLCR_ACTION_RETRY_SECONDS:-0.05}"
    local action_lease="${RLCR_ACTION_LEASE_SECONDS:-${CODEX_TIMEOUT:-5400}}"
    action_lease=$((action_lease + 60))
    RLCR_ACTION_PHASE="$phase"
    RLCR_ACTION_ROUND="$round"
    # Resolve the host-boot binding before entering any short lock section.
    rlcr_boot_identity >/dev/null || return 4

    while :; do
        rlcr_lock_acquire "$scope_dir" || return 1
        if [[ -f "$loop_dir/.cancel-requested" || -z "$(rlcr_active_state_file "$loop_dir")" ]]; then
            rlcr_lock_release
            return 3
        fi

        if [[ -s "$loop_dir/.pending-action-id" && -s "$loop_dir/.decision-outbox.json" ]]; then
            RLCR_ACTION_ID=$(sed -n '1p' "$loop_dir/.pending-action-id")
            RLCR_ACTION_EPOCH=$(rlcr_epoch_read "$loop_dir")
            local pending_epoch successor_generation successor_phase
            pending_epoch=$(sed -n '1p' "$loop_dir/.pending-action-epoch" 2>/dev/null || echo "")
            successor_generation=$(sed -n '1p' "$loop_dir/.pending-successor-generation" 2>/dev/null || true)
            successor_phase=$(sed -n '1p' "$loop_dir/.pending-successor-phase" 2>/dev/null || true)
            if rlcr_action_ack_is_committed "$loop_dir" "$RLCR_ACTION_ID" \
                "$successor_generation" "$successor_phase"; then
                local finalize_status=0
                rlcr_action_ack_finalize_locked "$loop_dir" || finalize_status=$?
                if [[ "$finalize_status" -ne 0 ]]; then
                    rlcr_lock_release
                    return 4
                fi
            elif [[ ! "$pending_epoch" =~ ^[0-9]+$ \
                  || ! "$successor_generation" =~ ^[0-9]+$ \
                  || -z "$successor_phase" ]] \
               || [[ "$pending_epoch" -gt "$RLCR_ACTION_EPOCH" ]] \
               || ! rlcr_pending_action_is_committed "$loop_dir" "$RLCR_ACTION_ID"; then
                # A writer died before the committing rename, or recovery
                # metadata is malformed.  It is safe to discard this physical
                # outbox because no logical action commit can be proven.
                rlcr_action_delivery_clear_locked "$loop_dir"
            elif rlcr_action_is_delivered "$loop_dir" "$RLCR_ACTION_ID" \
                 && [[ "${RLCR_OBSERVED_GENERATION:-}" == "$successor_generation" \
                  && "${RLCR_OBSERVED_PHASE:-}" == "$successor_phase" ]] \
                 && rlcr_successor_binds_action "$loop_dir" "$RLCR_ACTION_ID" \
                    "$successor_generation" "$successor_phase"; then
                local ack_status=0
                rlcr_action_ack_locked "$loop_dir" "$RLCR_ACTION_ID" \
                    "$successor_generation" "$successor_phase" || ack_status=$?
                if [[ "$ack_status" -ne 0 ]]; then
                    rlcr_lock_release
                    [[ "$ack_status" -eq 4 ]] && return 4
                    return 1
                fi
            else
                RLCR_ACTION_MODE="replay"
                rlcr_lock_release
                return 2
            fi
        fi

        local epoch inflight action_id inflight_epoch owner_pid owner_start_ticks
        local reviewer_protocol started now
        epoch=$(rlcr_epoch_read "$loop_dir")
        inflight="$loop_dir/.action-inflight"
        if [[ -f "$inflight" ]]; then
            if ! rlcr_inflight_record_valid "$inflight"; then
                echo "Error: malformed inflight action identity; recovery fenced" >&2
                rlcr_lock_release
                return 4
            fi
            action_id=$(rlcr_metadata_value "$inflight" action_id)
            inflight_epoch=$(rlcr_metadata_value "$inflight" epoch)
            owner_pid=$(rlcr_metadata_value "$inflight" pid)
            owner_start_ticks=$(rlcr_metadata_value "$inflight" hook_start_ticks)
            reviewer_protocol=$(rlcr_metadata_value "$inflight" reviewer_protocol)
            started=$(rlcr_metadata_value "$inflight" started)
            now=$(rlcr_now_epoch)
            [[ "$started" =~ ^[0-9]+$ ]] || started=0
            if [[ "$owner_pid" =~ ^[0-9]+$ ]] \
               && rlcr_process_matches_start "$owner_pid" "$owner_start_ticks"; then
                if [[ $((now - started)) -le "$action_lease" ]]; then
                    rlcr_lock_release
                    sleep "$retry_seconds"
                    continue
                fi
                # A live hook cannot be safely replaced: it could resume after
                # a lease-based takeover.  Fail closed instead of creating a
                # second worktree writer.
                echo "Error: inflight reviewer owner exceeded its lease but is still alive; recovery fenced" >&2
                rlcr_lock_release
                return 4
            fi
            if [[ "$inflight_epoch" != "$epoch" ]]; then
                # A non-action writer advanced the fence while Codex was
                # outside the lock.  The stale result cannot commit, but the
                # reservation may be removed only after its reviewer group is
                # mechanically proven EMPTY.
                local mismatch_terminate_status=0
                rlcr_reviewer_terminate_locked "$loop_dir" \
                    || mismatch_terminate_status=$?
                if [[ "$mismatch_terminate_status" -ne 0 ]]; then
                    rlcr_lock_release
                    return 4
                fi
                rm -f "$inflight"
                rlcr_lock_release
                continue
            fi
            local reviewer_terminate_status=0
            rlcr_reviewer_terminate_locked "$loop_dir" || reviewer_terminate_status=$?
            if [[ "$reviewer_protocol" != "pgid-v1" \
               || "$reviewer_terminate_status" -ne 0 ]]; then
                # The ADR forbids recovery when the old reviewer cannot be
                # identified and proven terminated.
                rlcr_lock_release
                return 4
            fi
            # Orphan writer: keep the canonical action id and fence epoch.
            RLCR_ACTION_ID="$action_id"
            RLCR_ACTION_EPOCH="$inflight_epoch"
            if ! rlcr_inflight_write_locked "$loop_dir" "$RLCR_ACTION_ID" "$RLCR_ACTION_EPOCH"; then
                rlcr_lock_release
                return 4
            fi
            RLCR_ACTION_MODE="leader-recovery"
            rlcr_lock_release
            return 0
        fi

        RLCR_ACTION_EPOCH="$epoch"
        # Reservation identity is not an action_id.  The final 64-hex action
        # id is bound after convergence and the reducer action are known.
        local reservation_digest reservation_hash
        reservation_digest=$(printf 'rlcr-action-reservation-v1' | rlcr_sha256_stream) || {
            rlcr_lock_release
            return 1
        }
        reservation_hash=$(rlcr_action_id "$(basename "$loop_dir")" "$epoch" "$round" \
            "$phase" "$reservation_digest" reservation "$RLCR_REDUCER_VERSION") || {
            rlcr_lock_release
            return 1
        }
        RLCR_ACTION_ID="reservation-${reservation_hash}"
        RLCR_ACTION_PHASE="$phase"
        if ! rlcr_inflight_write_locked "$loop_dir" "$RLCR_ACTION_ID" "$RLCR_ACTION_EPOCH"; then
            rlcr_lock_release
            return 4
        fi
        RLCR_ACTION_MODE="leader"
        rlcr_lock_release
        return 0
    done
}

rlcr_inflight_rebind_locked() {
    local inflight_file="$1" old_id="$2" new_id="$3" temp_file
    [[ -f "$inflight_file" ]] || return 1
    [[ "$(rlcr_metadata_value "$inflight_file" action_id)" == "$old_id" ]] || return 1
    temp_file="${inflight_file}.rebind.$$"
    awk -v replacement="$new_id" '
        /^action_id=/ { print "action_id=" replacement; found=1; next }
        { print }
        END { if (!found) exit 42 }
    ' "$inflight_file" > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    mv "$temp_file" "$inflight_file"
}

# Bind a reservation to the durable W4b action-id protocol after the reducer
# has selected its action.  Re-running after an orphan recovery is idempotent.
rlcr_action_bind() {
    local scope_dir="$1" loop_dir="$2" convergence_digest="$3" action="$4"
    local reducer_version="${5:-$RLCR_REDUCER_VERSION}"
    local canonical_phase="$RLCR_ACTION_PHASE" expected_id current_id
    case "$canonical_phase" in
        impl) canonical_phase=implementation ;;
        methodology) canonical_phase=methodology-analysis ;;
    esac
    [[ "$convergence_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    expected_id=$(rlcr_action_id "$(basename "$loop_dir")" "$RLCR_ACTION_EPOCH" \
        "$RLCR_ACTION_ROUND" "$canonical_phase" "$convergence_digest" "$action" \
        "$reducer_version") || return 1

    rlcr_lock_acquire "$scope_dir" || return 1
    current_id=$(rlcr_metadata_value "$loop_dir/.action-inflight" action_id)
    if [[ "$current_id" == "$expected_id" ]]; then
        RLCR_ACTION_ID="$expected_id"
        rlcr_lock_release
        return 0
    fi
    if [[ "$current_id" != "$RLCR_ACTION_ID" \
       || "$(rlcr_metadata_value "$loop_dir/.action-inflight" epoch)" != "$RLCR_ACTION_EPOCH" ]] \
       || ! rlcr_inflight_owned_by_current_hook "$loop_dir/.action-inflight" \
       || ! rlcr_inflight_rebind_locked "$loop_dir/.action-inflight" "$current_id" "$expected_id"; then
        rlcr_lock_release
        return 1
    fi
    RLCR_ACTION_ID="$expected_id"
    rlcr_lock_release
}

rlcr_action_outbox_publish_locked() {
    local loop_dir="$1" action_id="$2" successor_generation="$3"
    local successor_phase="$4" kind="$5" target="$6" decision_file="$7"
    local temp

    temp="$loop_dir/.decision-outbox.json.tmp.$$"
    cp "$decision_file" "$temp"
    mv "$temp" "$loop_dir/.decision-outbox.json"
    temp="$loop_dir/.pending-action-id.tmp.$$"
    printf '%s\n' "$action_id" > "$temp"
    mv "$temp" "$loop_dir/.pending-action-id"
    temp="$loop_dir/.pending-action-epoch.tmp.$$"
    printf '%s\n' "$successor_generation" > "$temp"
    mv "$temp" "$loop_dir/.pending-action-epoch"
    temp="$loop_dir/.pending-successor-generation.tmp.$$"
    printf '%s\n' "$successor_generation" > "$temp"
    mv "$temp" "$loop_dir/.pending-successor-generation"
    temp="$loop_dir/.pending-successor-phase.tmp.$$"
    printf '%s\n' "$successor_phase" > "$temp"
    mv "$temp" "$loop_dir/.pending-successor-phase"
    temp="$loop_dir/.pending-action-kind.tmp.$$"
    printf '%s\n' "$kind" > "$temp"
    mv "$temp" "$loop_dir/.pending-action-kind"
    temp="$loop_dir/.pending-action-target.tmp.$$"
    printf '%s\n' "$target" > "$temp"
    mv "$temp" "$loop_dir/.pending-action-target"
    rm -f "$loop_dir/.decision-delivered" "$loop_dir/.decision-claim"

    if [[ "${RLCR_TEST_KILL_AFTER_OUTBOX_COMMIT:-}" == "1" ]]; then
        kill -9 "$$"
    fi
}

rlcr_action_commit_same_state() {
    local scope_dir="$1" loop_dir="$2" action_id="$3" expected_epoch="$4"
    local decision_file="$5" state_file="$6"
    shift 6
    rlcr_lock_acquire "$scope_dir" || return 1
    local epoch inflight_id next_epoch state_temp successor_phase
    epoch=$(rlcr_epoch_read "$loop_dir")
    inflight_id=$(rlcr_metadata_value "$loop_dir/.action-inflight" action_id)
    if [[ -f "$loop_dir/.cancel-requested" || "$epoch" != "$expected_epoch" \
       || "$inflight_id" != "$action_id" || ! -f "$state_file" ]]; then
        rlcr_lock_release
        return 2
    fi
    if ! rlcr_inflight_owned_by_current_hook "$loop_dir/.action-inflight"; then
        rlcr_lock_release
        return 2
    fi
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    if [[ "$reviewer_fence_status" -ne 0 ]]; then
        rlcr_lock_release
        return 4
    fi
    next_epoch=$((epoch + 1))
    state_temp="${state_file}.action.$$"
    if ! rlcr_state_prepare "$state_file" "$state_temp" "$@" \
        "control_epoch=$next_epoch" \
        "pending_action_id=$action_id" \
        "pending_successor_generation=$next_epoch" \
        "last_applied_action_id=$action_id"; then
        rlcr_lock_release
        return 1
    fi
    successor_phase=$(rlcr_state_phase "$state_file" "$state_temp") || {
        rm -f "$state_temp"
        rlcr_lock_release
        return 1
    }
    if ! rlcr_state_prepare "$state_temp" "${state_temp}.phase" \
        "pending_successor_phase=$successor_phase"; then
        rm -f "$state_temp" "${state_temp}.phase"
        rlcr_lock_release
        return 1
    fi
    mv "${state_temp}.phase" "$state_temp"
    if ! rlcr_lock_heartbeat; then
        rm -f "$state_temp"
        rlcr_lock_release
        return 2
    fi

    if ! rlcr_publish_action_sidecars_locked; then
        rm -f "$state_temp"
        rlcr_lock_release
        return 1
    fi

    rlcr_action_outbox_publish_locked "$loop_dir" "$action_id" "$next_epoch" \
        "$successor_phase" same-state "$(basename "$state_file")" "$decision_file"
    rlcr_epoch_write_locked "$loop_dir" "$next_epoch"
    mv "$state_temp" "$state_file"
    if [[ "${RLCR_TEST_KILL_AFTER_STATE_COMMIT:-}" == "1" ]]; then
        kill -9 "$$"
    fi
    RLCR_ACTION_EPOCH="$next_epoch"
    rlcr_lock_release
}

rlcr_action_commit_phase() {
    local scope_dir="$1" loop_dir="$2" action_id="$3" expected_epoch="$4"
    local decision_file="$5" source_state="$6" target_state="$7"
    shift 7
    local -a transition_assignments=("$@")
    rlcr_lock_acquire "$scope_dir" || return 1
    local epoch inflight_id next_epoch state_temp successor_phase
    epoch=$(rlcr_epoch_read "$loop_dir")
    inflight_id=$(rlcr_metadata_value "$loop_dir/.action-inflight" action_id)
    if [[ -f "$loop_dir/.cancel-requested" || "$epoch" != "$expected_epoch" \
       || "$inflight_id" != "$action_id" || ! -f "$source_state" ]]; then
        rlcr_lock_release
        return 2
    fi
    if ! rlcr_inflight_owned_by_current_hook "$loop_dir/.action-inflight"; then
        rlcr_lock_release
        return 2
    fi
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    if [[ "$reviewer_fence_status" -ne 0 ]]; then
        rlcr_lock_release
        return 4
    fi
    next_epoch=$((epoch + 1))
    state_temp="${source_state}.action.$$"
    successor_phase=$(rlcr_state_phase "$target_state" "$source_state") || {
        rlcr_lock_release
        return 1
    }
    if ! rlcr_state_prepare "$source_state" "$state_temp" \
        "${transition_assignments[@]}" \
        "control_epoch=$next_epoch" \
        "pending_action_id=$action_id" \
        "pending_successor_generation=$next_epoch" \
        "pending_successor_phase=$successor_phase"; then
        rlcr_lock_release
        return 1
    fi
    if ! rlcr_lock_heartbeat; then
        rlcr_lock_release
        return 2
    fi
    if ! rlcr_publish_action_sidecars_locked; then
        rlcr_lock_release
        return 1
    fi
    rlcr_action_outbox_publish_locked "$loop_dir" "$action_id" "$next_epoch" \
        "$successor_phase" phase "$(basename "$target_state")" "$decision_file"
    # Preserve the single source->target phase rename as the logical commit
    # point while ensuring the successor state explicitly carries action_id.
    mv "$state_temp" "$source_state"
    rlcr_epoch_write_locked "$loop_dir" "$next_epoch"
    mv "$source_state" "$target_state"
    if [[ "${RLCR_TEST_KILL_AFTER_STATE_COMMIT:-}" == "1" ]]; then
        kill -9 "$$"
    fi
    RLCR_ACTION_EPOCH="$next_epoch"
    rlcr_lock_release
}

# Fence the actual stdout publication while holding the short control lock.
rlcr_action_emit() {
    local scope_dir="$1" loop_dir="$2" action_id="$3"
    rlcr_lock_acquire "$scope_dir" || return 1
    local pending_id pending_epoch current_epoch
    pending_id=$(sed -n '1p' "$loop_dir/.pending-action-id" 2>/dev/null || true)
    pending_epoch=$(sed -n '1p' "$loop_dir/.pending-action-epoch" 2>/dev/null || true)
    current_epoch=$(rlcr_epoch_read "$loop_dir")
    if [[ -f "$loop_dir/.cancel-requested" || "$pending_id" != "$action_id" \
       || ! "$pending_epoch" =~ ^[0-9]+$ || "$pending_epoch" -gt "$current_epoch" \
       || ! -s "$loop_dir/.decision-outbox.json" ]] \
       || ! rlcr_pending_action_is_committed "$loop_dir" "$action_id"; then
        rlcr_lock_release
        return 2
    fi
    if ! rlcr_lock_heartbeat; then
        rlcr_lock_release
        return 2
    fi
    if [[ "${RLCR_TEST_KILL_AFTER_ACTION_COMMIT:-}" == "1" ]]; then
        kill -9 "$$"
    fi
    cat "$loop_dir/.decision-outbox.json"
    if [[ "${RLCR_TEST_KILL_AFTER_DISPATCH:-}" == "1" ]]; then
        kill -9 "$$"
    fi
    local delivered_temp="$loop_dir/.decision-delivered.tmp.$$"
    printf '%s\n' "$action_id" > "$delivered_temp"
    mv "$delivered_temp" "$loop_dir/.decision-delivered"
    rlcr_lock_release
}

# Phase transition without Codex generation.  Sidecars/epoch are published
# first; the single source->target rename is the commit point.
rlcr_phase_transition() {
    local scope_dir="$1" loop_dir="$2" source_state="$3" target_state="$4"
    rlcr_lock_acquire "$scope_dir" || return 1
    if [[ -f "$loop_dir/.cancel-requested" || ! -f "$source_state" ]]; then
        rlcr_lock_release
        return 1
    fi
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    if [[ "$reviewer_fence_status" -ne 0 ]]; then
        rlcr_lock_release
        return 4
    fi
    local epoch
    epoch=$(rlcr_epoch_read "$loop_dir")
    if ! rlcr_lock_heartbeat; then
        rlcr_lock_release
        return 2
    fi
    rlcr_action_delivery_clear_locked "$loop_dir"
    rlcr_epoch_write_locked "$loop_dir" "$((epoch + 1))"
    mv "$source_state" "$target_state"
    rlcr_lock_release
}

rlcr_methodology_complete_transition() {
    local scope_dir="$1" loop_dir="$2" source_state="$3" target_state="$4"
    local reason_file="$loop_dir/.methodology-exit-reason"
    local claimed_reason="$loop_dir/.methodology-exit-reason.committing"
    rlcr_lock_acquire "$scope_dir" || return 1
    if [[ -f "$loop_dir/.cancel-requested" || ! -f "$source_state" ]]; then
        rlcr_lock_release
        return 1
    fi
    local reviewer_fence_status=0
    rlcr_epoch_writer_fence_locked "$loop_dir" || reviewer_fence_status=$?
    if [[ "$reviewer_fence_status" -ne 0 ]]; then
        rlcr_lock_release
        return 4
    fi
    if ! rlcr_lock_heartbeat; then
        rlcr_lock_release
        return 2
    fi
    if [[ -f "$reason_file" ]]; then
        mv "$reason_file" "$claimed_reason"
    elif [[ ! -f "$claimed_reason" ]]; then
        rlcr_lock_release
        return 1
    fi
    local epoch
    epoch=$(rlcr_epoch_read "$loop_dir")
    rlcr_action_delivery_clear_locked "$loop_dir"
    rlcr_epoch_write_locked "$loop_dir" "$((epoch + 1))"
    mv "$source_state" "$target_state"
    rm -f "$claimed_reason"
    rlcr_lock_release
}
