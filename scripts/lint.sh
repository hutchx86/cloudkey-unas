#!/bin/bash
# lint.sh
#
# Project lint: syntax-check every shell script and the Python helper, and
# run shellcheck when it's available. This is the project's canonical
# verification command -- there is no automated test suite for device-side
# behavior, which is verified on the Cloud Key via 05-verify.sh.
#
# Usage:
#   scripts/lint.sh
#
# Exit status: 0 if everything passed, 1 otherwise.
#
# The shellcheck tool is not installed by default in this environment. Install it
# however suits the host (distro package `shellcheck`, or
# `pip install shellcheck-py`); without it this script still runs `bash -n`
# on every script but prints a warning that the deeper check was skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0

log() { echo "[lint] $*"; }

# --- Collect shell scripts (tracked or not) from the pipeline and scripts/ ---
mapfile -t SHELL_SCRIPTS < <(
    find "$PROJECT_DIR/UNAS-CloudKey" "$PROJECT_DIR/scripts" \
        -type f -name '*.sh' | sort
)

# --- 1. bash -n: parse without executing ---
log "bash -n on ${#SHELL_SCRIPTS[@]} shell script(s)"
for f in "${SHELL_SCRIPTS[@]}"; do
    if bash -n "$f"; then
        :
    else
        log "  FAIL: bash -n $f"
        failures=$((failures + 1))
    fi
done

# --- 2. shellcheck, if available ---
if command -v shellcheck >/dev/null 2>&1; then
    log "shellcheck (severity >= warning) on ${#SHELL_SCRIPTS[@]} script(s)"
    if ! shellcheck -S warning "${SHELL_SCRIPTS[@]}"; then
        log "  FAIL: shellcheck reported findings above"
        failures=$((failures + 1))
    fi
else
    log "WARNING: shellcheck not found -- skipping static analysis"
    log "         install the 'shellcheck' package (or 'pip install shellcheck-py') to enable it"
fi

# --- 3. Python helper: byte-compile (in-memory, no __pycache__ written) ---
PY="$PROJECT_DIR/UNAS-CloudKey/lib/ssh_master.py"
if [[ -f "$PY" ]]; then
    log "compile $(basename "$PY")"
    if python3 - "$PY" <<'PYEOF'
import pathlib, sys
p = sys.argv[1]
compile(pathlib.Path(p).read_bytes(), p, "exec")
PYEOF
    then
        :
    else
        log "  FAIL: compile $PY"
        failures=$((failures + 1))
    fi
fi

if (( failures == 0 )); then
    log "PASS"
    exit 0
else
    log "FAIL: $failures check(s) failed"
    exit 1
fi
