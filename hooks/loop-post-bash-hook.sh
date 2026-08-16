#!/usr/bin/env bash
#
# PostToolUse Bash Hook for RLCR loop
#
# Records the Claude Code session_id into state.md immediately after setup.
# This hook fires right after the setup script's Bash command completes.
#
# Mechanism:
# 1. Setup script creates .humanize/.pending-session-id with:
#    Line 1: path to state.md
#    Line 2: full resolved path of setup script (command signature)
# 2. This hook checks for the signal file on every Bash PostToolUse event
# 3. Boundary-aware match: verifies the Bash command is a valid invocation
#    of the setup script path (path followed by end-of-string or whitespace),
#    preventing false positives from substrings and concatenated forms
# 4. Extracts session_id from hook JSON input
# 5. Patches state.md with the session_id value using safe awk replacement
# 6. Removes the signal file (one-shot mechanism)
#
# This ensures session_id is recorded BEFORE any team members can be created,
# so only the team leader (main session) is affected by RLCR loop hooks.
#

set -euo pipefail

# Read hook JSON input from stdin
HOOK_INPUT=$(cat)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/project-root.sh"
source "$SCRIPT_DIR/lib/loop-state-write.sh"

HOOK_COMMAND=""
HOOK_CWD=""
if command -v jq >/dev/null 2>&1; then
    HOOK_COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
    HOOK_CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
fi

# Verify the Bash command is a real setup script invocation (not arbitrary text)
# The command signature is the full resolved path of setup-rlcr-loop.sh.
# We require the command to START with this path (quoted or unquoted),
# preventing false positives like 'echo setup-rlcr-loop.sh' from consuming the signal.
matches_setup_command_signature() {
    local hook_command="$1"
    local command_signature="$2"

    # Older signal files did not include a command signature. Preserve the
    # previous behavior for those files.
    if [[ -z "$command_signature" ]]; then
        return 0
    fi

    if [[ -z "$hook_command" ]]; then
        return 1
    fi

    # Normalize consecutive slashes (e.g. "PolyArch//scripts" -> "PolyArch/scripts").
    # CLAUDE_PLUGIN_ROOT may have a trailing slash, producing double slashes when
    # concatenated with "/scripts/..." in the command template. The setup script
    # normalizes its own path via cd+pwd (removing double slashes), but the
    # tool_input.command preserves the original string. Without normalization,
    # the string comparison below always fails and session_id is never written.
    # See: https://github.com/PolyArch/humanize/issues/67
    hook_command=$(printf '%s' "$hook_command" | tr -s '/')
    command_signature=$(printf '%s' "$command_signature" | tr -s '/')

    # Boundary-aware match: command must be a valid setup invocation form.
    # Requires the script path to be followed by end-of-string or any POSIX
    # whitespace ([[:space:]]), preventing concatenated forms.
    # Accepts: "/full/path/setup-rlcr-loop.sh" args  (quoted, space-delimited)
    #          "/full/path/setup-rlcr-loop.sh"\targs  (quoted, tab-delimited)
    #          "/full/path/setup-rlcr-loop.sh"        (quoted, no args)
    #          /full/path/setup-rlcr-loop.sh args     (unquoted, space-delimited)
    #          /full/path/setup-rlcr-loop.sh\targs    (unquoted, tab-delimited)
    #          /full/path/setup-rlcr-loop.sh           (unquoted, no args)
    # Rejects: "/full/path/setup-rlcr-loop.sh"foo     (no boundary after quote)
    #          echo /full/path/setup-rlcr-loop.sh      (does not start with path)
    if [[ "$hook_command" == "\"${command_signature}\"" ]] || [[ "$hook_command" == "\"${command_signature}\""[[:space:]]* ]]; then
        return 0
    fi
    if [[ "$hook_command" == "${command_signature}" ]] || [[ "$hook_command" == "${command_signature}"[[:space:]]* ]]; then
        return 0
    fi

    return 1
}

resolve_candidate_root() {
    local candidate_dir="$1"
    local git_root=""

    if [[ -z "$candidate_dir" || ! -d "$candidate_dir" ]]; then
        return 1
    fi

    git_root=$(git -C "$candidate_dir" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$git_root" ]]; then
        canonicalize_path "$git_root"
    else
        canonicalize_path "$candidate_dir"
    fi
}

try_select_signal_file() {
    local candidate_dir="$1"
    local candidate_root=""
    local candidate_signal=""
    local candidate_state=""
    local candidate_signature=""

    candidate_root=$(resolve_candidate_root "$candidate_dir") || return 1
    candidate_signal="$candidate_root/.humanize/.pending-session-id"
    if [[ ! -f "$candidate_signal" ]]; then
        # A writer killed after claiming the handshake but before the state
        # commit leaves this recoverable signal behind.
        candidate_signal="${candidate_signal}.claimed"
        [[ -f "$candidate_signal" ]] || return 1
    fi

    {
        read -r candidate_state || true
        read -r candidate_signature || true
    } < "$candidate_signal"

    if matches_setup_command_signature "$HOOK_COMMAND" "$candidate_signature"; then
        PROJECT_ROOT="$candidate_root"
        SIGNAL_FILE="$candidate_signal"
        return 0
    fi

    return 1
}

# Locate the pending signal in the project associated with this hook event,
# not merely the shell process cwd. This avoids stale signals from a previous
# `cd` target claiming or blocking the setup command.
PROJECT_ROOT=""
SIGNAL_FILE=""
try_select_signal_file "$HOOK_CWD" \
    || try_select_signal_file "${CLAUDE_PROJECT_DIR:-}" \
    || try_select_signal_file "$(pwd)" \
    || true

if [[ -z "$SIGNAL_FILE" ]]; then
    # No pending session_id to record - this is the normal case
    exit 0
fi

# Read the signal file contents
# Line 1: state file path
# Line 2: full resolved path of setup script (command signature)
if [[ ! -f "$SIGNAL_FILE" && -f "${SIGNAL_FILE}.claimed" ]]; then
    SIGNAL_FILE="${SIGNAL_FILE}.claimed"
fi
[[ -f "$SIGNAL_FILE" ]] || exit 0
STATE_FILE_PATH=""
COMMAND_SIGNATURE=""
{
    read -r STATE_FILE_PATH || true
    read -r COMMAND_SIGNATURE || true
} < "$SIGNAL_FILE"

if [[ -z "$STATE_FILE_PATH" ]]; then
    exit 0
fi

# The setup handshake may only target a normal state file inside this project.
case "$STATE_FILE_PATH" in
    "$PROJECT_ROOT/.humanize/rlcr/"*/state.md) ;;
    *)
        echo "Warning: ignoring unsafe RLCR session handshake target: $STATE_FILE_PATH" >&2
        exit 0
        ;;
esac

# Re-check the selected signal before consuming it. Candidate selection above
# may have skipped stale signals from other roots, but this is the authorization gate.
if ! matches_setup_command_signature "$HOOK_COMMAND" "$COMMAND_SIGNATURE"; then
    # This Bash event is not from the setup script - do not consume signal
    exit 0
fi

# Extract session_id from the hook JSON input
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
    SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi

if [[ -z "$SESSION_ID" ]]; then
    # No session_id available in hook input - leave signal file for next attempt
    exit 0
fi

# Commit the session handshake under the same project-wide lease used by setup,
# cancel, and Stop.  Claiming the signal happens before the state rename; a
# SIGKILL leaves .claimed for the next PostToolUse event to recover.
LOOP_DIR=$(dirname "$STATE_FILE_PATH")
LOCK_SCOPE="$PROJECT_ROOT/.humanize/rlcr"
rlcr_lock_acquire "$LOCK_SCOPE" || exit 0

if [[ -f "$LOOP_DIR/.cancel-requested" || ! -f "$STATE_FILE_PATH" ]]; then
    rm -f "$SIGNAL_FILE"
    rlcr_lock_release
    exit 0
fi
REVIEWER_FENCE_STATUS=0
rlcr_epoch_writer_fence_locked "$LOOP_DIR" || REVIEWER_FENCE_STATUS=$?
if [[ "$REVIEWER_FENCE_STATUS" -ne 0 ]]; then
    rlcr_lock_release
    exit 4
fi
if ! rlcr_lock_heartbeat; then
    rlcr_lock_release
    exit 0
fi

CURRENT_SESSION_ID=$(grep "^session_id:" "$STATE_FILE_PATH" 2>/dev/null | sed 's/session_id: *//' || echo "")
if [[ -z "$CURRENT_SESSION_ID" ]]; then
    CLAIMED_SIGNAL="$PROJECT_ROOT/.humanize/.pending-session-id.claimed"
    if [[ "$SIGNAL_FILE" != "$CLAIMED_SIGNAL" ]]; then
        mv "$SIGNAL_FILE" "$CLAIMED_SIGNAL"
        SIGNAL_FILE="$CLAIMED_SIGNAL"
    fi

    EPOCH=$(rlcr_epoch_read "$LOOP_DIR")
    NEXT_EPOCH=$((EPOCH + 1))
    TEMP_FILE="${STATE_FILE_PATH}.session.$$"
    if ! rlcr_state_prepare "$STATE_FILE_PATH" "$TEMP_FILE" \
        "session_id=$SESSION_ID" "control_epoch=$NEXT_EPOCH"; then
        rm -f "$SIGNAL_FILE"
        rlcr_lock_release
        exit 0
    fi
    rlcr_epoch_write_locked "$LOOP_DIR" "$NEXT_EPOCH"
    mv "$TEMP_FILE" "$STATE_FILE_PATH"
fi

# One-shot cleanup after the committing rename.  If this cleanup is killed,
# the next event observes the already-populated session_id and removes it.
rm -f "$SIGNAL_FILE" "$PROJECT_ROOT/.humanize/.pending-session-id" \
      "$PROJECT_ROOT/.humanize/.pending-session-id.claimed"
rlcr_lock_release

exit 0
