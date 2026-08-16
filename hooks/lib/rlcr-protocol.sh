#!/usr/bin/env bash
# Deterministic, zero-side-effect RLCR protocol primitives.

[[ -n "${_RLCR_PROTOCOL_LOADED:-}" ]] && return 0 2>/dev/null || true
_RLCR_PROTOCOL_LOADED=1

readonly RLCR_REDUCER_VERSION="rlcr-reducer-v1"

rlcr_sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        return 1
    fi
}

# Hash a tagged, length-prefixed record.  Lengths make the encoding
# unambiguous; this is deliberately not raw string concatenation.
rlcr_action_id() {
    local run_id="$1" source_generation="$2" round="$3" phase="$4"
    local convergence_digest="$5" action="$6" reducer_version="${7:-$RLCR_REDUCER_VERSION}"
    {
        printf 'rlcr-action-id-v1\n'
        printf '%s:%s:%s:%s\n' 6 run_id "${#run_id}" "$run_id"
        printf '%s:%s:%s:%s\n' 17 source_generation "${#source_generation}" "$source_generation"
        printf '%s:%s:%s:%s\n' 5 round "${#round}" "$round"
        printf '%s:%s:%s:%s\n' 5 phase "${#phase}" "$phase"
        printf '%s:%s:%s:%s\n' 18 convergence_digest "${#convergence_digest}" "$convergence_digest"
        printf '%s:%s:%s:%s\n' 6 action "${#action}" "$action"
        printf '%s:%s:%s:%s\n' 15 reducer_version "${#reducer_version}" "$reducer_version"
    } | rlcr_sha256_stream
}

rlcr_action_id_compute() {
    rlcr_action_id "$@"
}
