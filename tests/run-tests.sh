#!/bin/sh
# tests/run-tests.sh: executes every tests/t-*.sh in filename order, each in
# its own `sh` process (so one test's exit/crash can never corrupt another
# test's sandbox or shell state). Prints one PASS/FAIL line per test, then a
# summary line "N passed, M failed"; exits nonzero if any test failed.
# POSIX sh only (see AGENTS.md); no bats.
set -u

PQR_SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

PQR_TMP="$(mktemp "${TMPDIR:-/tmp}/pq-run-tests.XXXXXX")" || {
    echo "run-tests: mktemp failed" >&2
    exit 1
}
trap 'rm -f "$PQR_TMP"' EXIT INT TERM

PQR_PASSED=0
PQR_FAILED=0

for pqr_test in "$PQR_SELF_DIR"/t-*.sh; do
    [ -e "$pqr_test" ] || continue
    pqr_name="$(basename "$pqr_test")"
    if sh "$pqr_test" >"$PQR_TMP" 2>&1; then
        printf 'PASS %s\n' "$pqr_name"
        PQR_PASSED=$((PQR_PASSED + 1))
    else
        printf 'FAIL %s\n' "$pqr_name"
        sed 's/^/  /' "$PQR_TMP"
        PQR_FAILED=$((PQR_FAILED + 1))
    fi
done

printf '%s passed, %s failed\n' "$PQR_PASSED" "$PQR_FAILED"
[ "$PQR_FAILED" -eq 0 ]
