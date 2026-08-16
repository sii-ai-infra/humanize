#!/usr/bin/env bash
# D5 regression proofs for the canonical RLCR solution candidate fingerprint.

set -uo pipefail

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/hooks/lib/rlcr-protocol.sh"
source "$PLUGIN_ROOT/hooks/lib/rlcr-control.sh"

PASSED=0
FAILED=0

record_change() {
    local label="$1" command="$2" before="$3" after="$4"
    local result=FAIL
    if [[ "$before" != "$after" ]]; then
        result=PASS
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    printf '%s command=%q before=%s after=%s result=%s\n' \
        "$label" "$command" "$before" "$after" "$result"
}

record_same() {
    local label="$1" command="$2" before="$3" after="$4"
    local result=FAIL
    if [[ "$before" == "$after" ]]; then
        result=PASS
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
    printf '%s command=%q before=%s after=%s result=%s\n' \
        "$label" "$command" "$before" "$after" "$result"
}

make_repository() {
    local repository="$1" reverse_order="${2:-false}"
    mkdir -p "$repository/solution"
    if [[ "$reverse_order" == true ]]; then
        printf 'UVWXYZ\n' > "$repository/solution/content.txt"
        printf 'mode\n' > "$repository/solution/mode.txt"
        printf 'delete\n' > "$repository/solution/delete.txt"
    else
        printf 'delete\n' > "$repository/solution/delete.txt"
        printf 'mode\n' > "$repository/solution/mode.txt"
        printf 'UVWXYZ\n' > "$repository/solution/content.txt"
    fi
    chmod 0644 "$repository/solution/"*.txt
    git -C "$repository" init -q
    git -C "$repository" config user.email test@example.com
    git -C "$repository" config user.name "RLCR Fingerprint Test"
    git -C "$repository" config commit.gpgsign false
    git -C "$repository" add solution
    git -C "$repository" commit -q -m "fingerprint fixture $reverse_order"
}

REPOSITORY="$TEST_DIR/repository"
make_repository "$REPOSITORY"
BASELINE=$(rlcr_candidate_fingerprint "$REPOSITORY")

rm "$REPOSITORY/solution/delete.txt"
DELETED=$(rlcr_candidate_fingerprint "$REPOSITORY")
record_change DELETE "rm solution/delete.txt" "$BASELINE" "$DELETED"
printf 'delete\n' > "$REPOSITORY/solution/delete.txt"
chmod 0644 "$REPOSITORY/solution/delete.txt"

chmod +x "$REPOSITORY/solution/mode.txt"
MODE_CHANGED=$(rlcr_candidate_fingerprint "$REPOSITORY")
record_change MODE "chmod +x solution/mode.txt" "$BASELINE" "$MODE_CHANGED"
chmod 0644 "$REPOSITORY/solution/mode.txt"

printf 'ABCDEF\n' > "$REPOSITORY/solution/content.txt"
CONTENT_CHANGED=$(rlcr_candidate_fingerprint "$REPOSITORY")
record_change CONTENT_SAME_SIZE "printf ABCDEF\\n > solution/content.txt" \
    "$BASELINE" "$CONTENT_CHANGED"
printf 'UVWXYZ\n' > "$REPOSITORY/solution/content.txt"

printf 'untracked\n' > "$REPOSITORY/solution/untracked.txt"
UNTRACKED_ADDED=$(rlcr_candidate_fingerprint "$REPOSITORY")
record_change UNTRACKED "printf untracked\\n > solution/untracked.txt" \
    "$BASELINE" "$UNTRACKED_ADDED"
rm "$REPOSITORY/solution/untracked.txt"

STABLE_FIRST=$(rlcr_candidate_fingerprint "$REPOSITORY")
STABLE_SECOND=$(rlcr_candidate_fingerprint "$REPOSITORY")
record_same STABLE_TWICE "rlcr_candidate_fingerprint twice" \
    "$STABLE_FIRST" "$STABLE_SECOND"

ORDER_REPOSITORY="$TEST_DIR/reverse-order-repository"
make_repository "$ORDER_REPOSITORY" true
touch -t 200101010101 "$REPOSITORY/solution/"*.txt
touch -t 203012312359 "$ORDER_REPOSITORY/solution/"*.txt
ORDER_FIRST=$(rlcr_candidate_fingerprint "$REPOSITORY")
ORDER_SECOND=$(rlcr_candidate_fingerprint "$ORDER_REPOSITORY")
record_same ORDER_AND_MTIME \
    "same files created in reverse order with different mtimes" \
    "$ORDER_FIRST" "$ORDER_SECOND"

printf 'SUMMARY passed=%d failed=%d\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
