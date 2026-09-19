#!/bin/bash
# lint.sh -- project verification: bash -n on every shell script, shellcheck
# (severity >= warning) when available, and a byte-compile of the Python helper.
# There is no automated device-side test suite; behaviour is verified separately
# via UNAS-CloudKey/05-verify.sh.
#
# Usage: scripts/lint.sh   (exit 0 if all passed, 1 otherwise)
#
# The shellcheck tool is optional; install the distro `shellcheck` package or
# `pip install shellcheck-py`, otherwise only bash -n runs (with a warning).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0

log() { echo "[lint] $*"; }

# --- Collect shell scripts from UNAS-CloudKey/, scripts/, and the repo root ---
mapfile -t SHELL_SCRIPTS < <(
    {
        find "$PROJECT_DIR/UNAS-CloudKey" "$PROJECT_DIR/scripts" \
            -type f -name '*.sh'
        find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.sh'
    } | sort -u
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
