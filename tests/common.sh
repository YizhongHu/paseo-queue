#!/bin/sh
# tests/common.sh: sourced (`. "$(dirname "$0")/common.sh"`) by every
# tests/t-*.sh. Provides a fresh sandboxed environment per test (mktemp
# sandbox + the mock paseo shim first on PATH + fast dispatcher knobs) and a
# handful of assertion/helper functions. POSIX sh only (see AGENTS.md): no
# bashisms, no bats, macOS /bin/sh = bash 3.2 in sh mode.
set -u

PQT_SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PQT_REPO_ROOT="$(CDPATH= cd -- "$PQT_SELF_DIR/.." && pwd)"
PQT_BIN="$PQT_REPO_ROOT/bin/paseo-queue"
PQT_MOCK_SRC="$PQT_REPO_ROOT/tests/mock/paseo"

# Populated by setup(); consumed by teardown()/fail().
SANDBOX=""
MOCK_DIR=""
PQT_REAL_HOME_BEFORE=""

setup() {
    # setup -- creates a fresh mktemp sandbox, puts the mock paseo shim
    # first on PATH (as the literal name "paseo"), points
    # PASEO_QUEUE_HOME/MOCK_DIR at sandbox subdirectories (exported so a
    # backgrounded `_dispatch` child inherits them), and applies the fast
    # test knobs bin/paseo-queue documents in its usage().
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/pq-test.XXXXXX")" || {
        echo "setup: mktemp -d failed" >&2
        exit 1
    }
    mkdir -p "$SANDBOX/bin" "$SANDBOX/home" "$SANDBOX/mock"

    cp "$PQT_MOCK_SRC" "$SANDBOX/bin/paseo"
    chmod +x "$SANDBOX/bin/paseo"

    PATH="$SANDBOX/bin:$PATH"
    export PATH

    PASEO_QUEUE_HOME="$SANDBOX/home"
    export PASEO_QUEUE_HOME

    MOCK_DIR="$SANDBOX/mock"
    export MOCK_DIR

    # Fast knobs: shrink every wait/backoff/timeout so a full test run stays
    # in the single-digit seconds even through several dispatcher cycles.
    # PASEO_QUEUE_BACKOFF_SCALE=0 collapses the daemon/hold/send backoff
    # schedules (dp_scale_seconds multiplies by this) to 0s without changing
    # which branch of the dispatcher runs.
    PASEO_QUEUE_LINGER=1
    PASEO_QUEUE_WAIT_TIMEOUT=2
    PASEO_QUEUE_HOLD_LOG_EVERY=2
    PASEO_QUEUE_BACKOFF_SCALE=0
    export PASEO_QUEUE_LINGER PASEO_QUEUE_WAIT_TIMEOUT PASEO_QUEUE_HOLD_LOG_EVERY PASEO_QUEUE_BACKOFF_SCALE

    : > "$MOCK_DIR/agents.tsv"
    : > "$MOCK_DIR/calls.log"

    # Snapshot the REAL $HOME/.paseo-queue agent directories. teardown()
    # checks that no synthetic test-agent directory leaked there. Comparing
    # total entry counts is intentionally avoided: unrelated live dispatchers
    # may add or remove their own queue files while this suite runs.
    PQT_REAL_HOME_BEFORE="$SANDBOX/real-home-before.txt"
    : > "$PQT_REAL_HOME_BEFORE"
    for pqt_real_agent in "$HOME"/.paseo-queue/*; do
        [ -d "$pqt_real_agent" ] || continue
        printf '%s\n' "$pqt_real_agent" >> "$PQT_REAL_HOME_BEFORE"
    done
    LC_ALL=C sort -o "$PQT_REAL_HOME_BEFORE" "$PQT_REAL_HOME_BEFORE"
}

teardown() {
    # teardown -- terminates any dispatcher(s) still alive for this sandbox
    # (identified via each agent dir's own lock/pid, the same liveness
    # signal bin/paseo-queue itself trusts: kill -0 + `ps` command match),
    # asserts the real $HOME/.paseo-queue was never touched, then removes
    # the sandbox. Safe to call more than once and safe to call after a
    # failed assertion (fail() exits, and callers are expected to `trap
    # teardown EXIT` so it always runs).
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX/home" ]; then
        for pqt_lockpid in "$SANDBOX"/home/*/lock/pid; do
            [ -e "$pqt_lockpid" ] || continue
            pqt_pid="$(cat "$pqt_lockpid" 2>/dev/null)"
            case "$pqt_pid" in
                ''|*[!0-9]*) continue ;;
            esac
            if kill -0 "$pqt_pid" 2>/dev/null; then
                if ps -p "$pqt_pid" -o command= 2>/dev/null | grep -q 'paseo-queue'; then
                    kill -TERM "$pqt_pid" 2>/dev/null
                fi
            fi
        done
    fi

    pqt_real_leak=""
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX/home" ]; then
        for pqt_local_agent in "$SANDBOX"/home/*; do
            [ -d "$pqt_local_agent" ] || continue
            pqt_agent_name="$(basename "$pqt_local_agent")"
            pqt_real_agent="$HOME/.paseo-queue/$pqt_agent_name"
            if [ -d "$pqt_real_agent" ] && ! grep -Fqx -- "$pqt_real_agent" "$PQT_REAL_HOME_BEFORE"; then
                pqt_real_leak="$pqt_real_agent"
                break
            fi
        done
    fi
    if [ -n "$pqt_real_leak" ]; then
        # Preserve the sandbox for forensics instead of deleting it -- this
        # should never happen if the harness is working correctly.
        echo "FAIL: test agent state leaked into real \$HOME/.paseo-queue: $pqt_real_leak" >&2
        echo "  sandbox preserved for inspection: $SANDBOX" >&2
        exit 1
    fi

    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        rm -rf "$SANDBOX"
    fi
}

fail() {
    # fail <message...> -- prints a FAIL diagnostic (with the sandbox path,
    # so a failure can be inspected before it's cleaned up) and exits 1.
    echo "FAIL: $*" >&2
    [ -n "$SANDBOX" ] && echo "  sandbox: $SANDBOX" >&2
    exit 1
}

assert_eq() {
    # assert_eq <actual> <expected> [message]
    ae_actual="$1"; ae_expected="$2"; ae_msg="${3:-assert_eq}"
    [ "$ae_actual" = "$ae_expected" ] || fail "$ae_msg: expected [$ae_expected], got [$ae_actual]"
}

assert_rc() {
    # assert_rc <expected_rc> <actual_rc> [message]
    ar_expected="$1"; ar_actual="$2"; ar_msg="${3:-assert_rc}"
    [ "$ar_actual" = "$ar_expected" ] || fail "$ar_msg: expected rc=$ar_expected, got rc=$ar_actual"
}

assert_grep() {
    # assert_grep <file> <pattern> [message] -- asserts <file> contains a
    # line matching the basic regular expression <pattern>.
    ag_file="$1"; ag_pattern="$2"; ag_msg="${3:-assert_grep}"
    [ -f "$ag_file" ] || fail "$ag_msg: file not found: $ag_file"
    grep -q -- "$ag_pattern" "$ag_file" || fail "$ag_msg: pattern [$ag_pattern] not found in $ag_file"
}

wait_until() {
    # wait_until <cmd-string> <timeout-seconds> -- polls `sh -c "$cmd"`
    # once per second until it exits 0; fails the test if <timeout-seconds>
    # elapse first.
    wu_cmd="$1"; wu_timeout="$2"
    wu_elapsed=0
    while [ "$wu_elapsed" -lt "$wu_timeout" ]; do
        sh -c "$wu_cmd" && return 0
        sleep 1
        wu_elapsed=$((wu_elapsed + 1))
    done
    fail "wait_until: condition never became true within ${wu_timeout}s: $wu_cmd"
}

seed_agent() {
    # seed_agent <uuid> <name> [status=idle] [archived=0] [nperms=0] --
    # appends one row to $MOCK_DIR/agents.tsv; shortId is derived as the
    # first 7 characters of <uuid> (matches bin/paseo-queue's own
    # convention, see its `ca_short="$(printf '%.7s' "$ca_uuid")"`).
    sa_uuid="$1"; sa_name="$2"
    sa_status="${3:-idle}"
    sa_archived="${4:-0}"
    sa_nperms="${5:-0}"
    sa_short="$(printf '%.7s' "$sa_uuid")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$sa_uuid" "$sa_short" "$sa_name" "$sa_status" "$sa_archived" "$sa_nperms" \
        >> "$MOCK_DIR/agents.tsv"
}

gen_uuid() {
    # gen_uuid -- prints a fresh, well-formed-shape (8-4-4-4-12) fake UUID:
    # deterministic and unique within this test process. Digits only (the
    # product's own pq_is_full_uuid() shape check accepts any characters in
    # those positions, only the grouping/length matters), seeded with $$ so
    # two test processes never collide.
    PQT_UUID_SEQ="${PQT_UUID_SEQ:-0}"
    PQT_UUID_SEQ=$((PQT_UUID_SEQ + 1))
    printf '%08d-%04d-%04d-%04d-%07d%05d\n' "$PQT_UUID_SEQ" 0 0 0 "$$" "$PQT_UUID_SEQ"
}

mock_set_wait_script() {
    # mock_set_wait_script <line> [<line> ...] -- appends one wait.script
    # line per argument (see tests/mock/paseo's file-format header comment
    # for the line grammar), each guaranteed a trailing newline.
    for msw_line in "$@"; do
        printf '%s\n' "$msw_line" >> "$MOCK_DIR/wait.script"
    done
}

mock_set_send_script() {
    # mock_set_send_script <line> [<line> ...] -- appends one send.script
    # line per argument, each guaranteed a trailing newline.
    for mss_line in "$@"; do
        printf '%s\n' "$mss_line" >> "$MOCK_DIR/send.script"
    done
}

mock_agent_status() {
    # mock_agent_status <uuid> -- prints the current status field for
    # <uuid> from $MOCK_DIR/agents.tsv (nothing, rc=1, if not found).
    [ -f "$MOCK_DIR/agents.tsv" ] || return 1
    while IFS='	' read -r mas_u _ _ mas_status _ _ || [ -n "$mas_u" ]; do
        if [ "$mas_u" = "$1" ]; then
            printf '%s\n' "$mas_status"
            return 0
        fi
    done < "$MOCK_DIR/agents.tsv"
    return 1
}

mock_send_count() {
    # mock_send_count -- prints the number of recorded deliveries (lines in
    # $MOCK_DIR/send.log; 0 if the file doesn't exist yet).
    if [ -f "$MOCK_DIR/send.log" ]; then
        wc -l < "$MOCK_DIR/send.log" | tr -d ' '
    else
        printf '0\n'
    fi
}

mock_calls_count() {
    # mock_calls_count -- prints the number of recorded mock invocations
    # (lines in $MOCK_DIR/calls.log; 0 if the file doesn't exist yet).
    if [ -f "$MOCK_DIR/calls.log" ]; then
        wc -l < "$MOCK_DIR/calls.log" | tr -d ' '
    else
        printf '0\n'
    fi
}
