#!/bin/sh
# tests/t-21-stop-drain-receipts.sh: stop and drain must report what they did,
# and stop must be idempotent.
#
# Issue #10: the observability fix in #3 covered add and rm but left these two
# behind, with the polarity inverted. `stop` SIGTERM'd a live dispatcher and
# printed NOTHING while exiting 0; `stop` with nothing running printed a
# message and exited 1. The consequential path was silent and the harmless
# no-op called itself an error. `drain` was silent too, which matters because
# `status` explicitly tells callers to run drain.
#
# Decision recorded here: stop is now idempotent (exit 0 either way) and both
# commands print receipts. Callers that need to distinguish "terminated
# something" from "already stopped" read the receipt, which says which
# happened -- more explicitly than an exit code could.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000021-0000-0000-0000-000000000021"
seed_agent "$AGENT_UUID" "t21-agent" running 0 0
dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

wait_for() {
    wf_cond="$1"; wf_timeout="$2"
    wf_elapsed=0
    while [ "$wf_elapsed" -lt "$wf_timeout" ]; do
        eval "$wf_cond" && return 0
        sleep 1
        wf_elapsed=$((wf_elapsed + 1))
    done
    return 1
}

# --- stop with nothing running: SUCCESS, and it says so ------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "t21 seed" --quiet
assert_rc 0 "$?" "seeding the queue should succeed"

"$PQT_BIN" stop "$AGENT_UUID" >"$SANDBOX/stop-none.out" 2>"$SANDBOX/stop-none.err"
assert_rc 0 "$?" "stop with nothing running must exit 0 (idempotent ensure-stopped)"
assert_grep "$SANDBOX/stop-none.out" "already stopped" \
    "stop should report that nothing was running"
[ ! -s "$SANDBOX/stop-none.err" ] \
    || fail "an idempotent stop should not write to stderr (got: $(cat "$SANDBOX/stop-none.err"))"

# --- drain reports that it spawned a dispatcher -------------------------
mock_set_wait_script "after=25 result=idle set_status=idle"

"$PQT_BIN" drain "$AGENT_UUID" >"$SANDBOX/drain1.out" 2>&1
assert_rc 0 "$?" "drain should exit 0"
assert_grep "$SANDBOX/drain1.out" "^paseo-queue: drained a000002 (spawned a dispatcher)$" \
    "drain should report that it spawned a dispatcher"

wait_for '[ -s "'"$dp_dir"'/lock/pid" ]' 15 \
    || fail "drain should have produced a live dispatcher"
t21_pid="$(cat "$dp_dir/lock/pid" | tr -d ' ')"
[ -n "$t21_pid" ] || fail "dispatcher pid file is empty"

# --- drain again, with one already live: says so, and names the pid -----
"$PQT_BIN" drain "$AGENT_UUID" >"$SANDBOX/drain2.out" 2>&1
assert_rc 0 "$?" "a redundant drain should still exit 0"
assert_grep "$SANDBOX/drain2.out" "dispatcher already live, pid=$t21_pid" \
    "a redundant drain should report the live dispatcher and its pid"

# --- stop with a live dispatcher: names what it killed ------------------
"$PQT_BIN" stop "$AGENT_UUID" >"$SANDBOX/stop-live.out" 2>&1
assert_rc 0 "$?" "stop with a live dispatcher should exit 0"
assert_grep "$SANDBOX/stop-live.out" "^paseo-queue: stopped a000002 dispatcher pid=$t21_pid$" \
    "stop must name the dispatcher it terminated"

# The two receipts must be distinguishable, since that is what replaces the
# exit-code signal for callers who care which happened.
grep -q "already stopped" "$SANDBOX/stop-live.out" \
    && fail "the live-kill receipt must not read as an already-stopped no-op"

# --- --quiet silences both, on both streams ----------------------------
"$PQT_BIN" drain "$AGENT_UUID" --quiet >"$SANDBOX/drain-q.out" 2>"$SANDBOX/drain-q.err"
assert_rc 0 "$?" "drain --quiet should exit 0"
[ ! -s "$SANDBOX/drain-q.out" ] || fail "drain --quiet must print nothing on stdout"
[ ! -s "$SANDBOX/drain-q.err" ] || fail "drain --quiet must print nothing on stderr"

"$PQT_BIN" stop "$AGENT_UUID" --quiet >"$SANDBOX/stop-q.out" 2>"$SANDBOX/stop-q.err"
assert_rc 0 "$?" "stop --quiet should exit 0"
[ ! -s "$SANDBOX/stop-q.out" ] || fail "stop --quiet must print nothing on stdout"
[ ! -s "$SANDBOX/stop-q.err" ] || fail "stop --quiet must print nothing on stderr"

# --- unknown options still rejected -----------------------------------
"$PQT_BIN" stop "$AGENT_UUID" --bogus >/dev/null 2>"$SANDBOX/stop-bad.err"
assert_rc 1 "$?" "stop with an unknown option should exit 1"
assert_grep "$SANDBOX/stop-bad.err" "stop: unknown option: --bogus" \
    "stop should name the unknown option"

"$PQT_BIN" drain "$AGENT_UUID" --bogus >/dev/null 2>"$SANDBOX/drain-bad.err"
assert_rc 1 "$?" "drain with an unknown option should exit 1"
assert_grep "$SANDBOX/drain-bad.err" "drain: unknown option: --bogus" \
    "drain should name the unknown option"

# --- the queue is never touched by either command ----------------------
t21_pending=0
for t21_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t21_f" ] || continue
    t21_pending=$((t21_pending + 1))
done
assert_eq "$t21_pending" "1" "stop and drain must leave the queue itself untouched"

exit 0
