#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run every suite that does not need a built image.
#
#   pi-image/tests/run-all.sh
#
# test_built_image.sh is excluded: it needs Linux, root, and an actual
# .img.xz to audit. Run it by hand after a build.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

FAILED=""
run() {   # run <label> <command...>
    local label="$1"; shift
    echo
    echo "=== $label ==="
    if "$@"; then
        echo "--- $label: PASS"
    else
        echo "--- $label: FAIL" >&2
        FAILED="$FAILED $label"
    fi
}

# Syntax first: a parse error in any of these makes the rest meaningless.
run "shell syntax"        bash -n "$ROOT"/pi-image/*.sh "$ROOT"/pi-image/tests/*.sh
run "motor spec renderer" bash -c '
    set -e
    . "'"$ROOT"'/pi-image/pi-app.env"
    bash "'"$ROOT"'/pi-image/render-motor-args.sh" "$MOTORS" >/dev/null
    for bad in "a:22,23 b:22,6" "a:22,99" "A:22,23" "a:22,23 a:5,6" "nocolon"; do
        if bash "'"$ROOT"'/pi-image/render-motor-args.sh" "$bad" >/dev/null 2>&1; then
            echo "accepted an invalid spec: $bad" >&2; exit 1
        fi
    done'
run "write-time config"   bash "$HERE/test_firstboot.sh"
run "flasher wiring"      bash "$HERE/test_bootstrap.sh"
run "cscript phase 0"     bash "$HERE/test_cscript_phase0.sh"

# The server suite needs flask; skip with a clear reason rather than a failure
# that says nothing about the code.
if python -c 'import flask, flask_caching' 2>/dev/null; then
    run "two-motor server" python "$HERE/test_motor_server.py"
elif command -v uv >/dev/null 2>&1; then
    run "two-motor server" uv run --no-project --with flask --with flask-caching \
        python "$HERE/test_motor_server.py"
else
    echo
    echo "=== two-motor server ==="
    echo "SKIP: needs flask and flask-caching (or uv). Install them, or run:"
    echo "  uv run --no-project --with flask --with flask-caching python $HERE/test_motor_server.py"
fi

echo
echo "========================================"
if [ -n "$FAILED" ]; then
    echo "FAILED:$FAILED" >&2
    exit 1
fi
echo "all suites passed"
