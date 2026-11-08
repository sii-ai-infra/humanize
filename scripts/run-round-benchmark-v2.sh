#!/usr/bin/env bash
set -euo pipefail

# No login shell or task-supplied Python search path. Node fixes this resource
# and the five original arguments before claiming the controller operation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3.12 -I -S -B "$SCRIPT_DIR/run-round-benchmark-v2.py" "$@"
