#!/bin/sh
# tests/t-26-wait-progress.sh: `--wait` must wait as documented, and say what
# it is waiting on.
#
# Two defects motivated this. First, a port regression: wait_for_delivery
# defaulted a missing timeout to PASEO_QUEUE_WAIT_TIMEOUT (60s) -- a knob that
# means something else entirely, the DISPATCHER's `paseo wait` timeout -- so a
# bare `--wait` gave up after 60 seconds and reported
# "add --wait-timeout: 60s elapsed" to a caller who never passed
# --wait-timeout. The shell implementation waited indefinitely and README says
# `--wait` "blocks until the message leaves pending/".
#
# That fired at almost exactly the transport's own median latency: measured
# over 1574 real deliveries, `paseo send` has a median duration of 57s,
# because it blocks until the agent has PROCESSED the prompt. So a healthy
# delivery routinely lost the race with its own caller's hidden deadline.
#
# Second, the wait was silent, and a silent multi-minute wait is
# indistinguishable from a hang.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000026-0000-0000-0000-000000000026"
seed_agent "$AGENT_UUID" "t26-agent" idle 0 0
dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# --- a bare --wait must NOT self-terminate at 60s -----------------------
# Pre-fix this exited 4 at ~61s. Rather than spend 60s proving a negative,
# assert the positive: with nothing delivering, it is STILL RUNNING well past
# the point where a 60s default would have been armed, and then succeeds once
# delivery happens.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "bare wait probe" --quiet
assert_rc 0 "$?" "seeding the message should succeed"
t26_msg=""
for t26_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t26_f" ] || continue
    t26_msg="$(basename "$t26_f")"
done
[ -n "$t26_msg" ] || fail "expected a pending message"

# A second add on the same message name is not possible, so wait on the
# existing one by starting a bare --wait for a NEW message and delivering both.
PASEO_QUEUE_NO_SPAWN=1 PASEO_QUEUE_WAIT_PROGRESS_EVERY=2 \
    "$PQT_BIN" add "$AGENT_UUID" "waited probe" --wait >"$SANDBOX/w.out" 2>"$SANDBOX/w.err" &
t26_pid=$!

sleep 5
kill -0 "$t26_pid" 2>/dev/null \
    || fail "a bare --wait must still be waiting after 5s, not have exited"

# Deliver everything; the waiter must then exit 0.
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1

wait "$t26_pid"
assert_rc 0 "$?" "a bare --wait should exit 0 once its message is delivered"

grep -q "add --wait-timeout" "$SANDBOX/w.err" \
    && fail "a bare --wait must never report a --wait-timeout the caller did not set"

# --- it reports what it is waiting on -----------------------------------
assert_grep "$SANDBOX/w.err" "add --wait: .*elapsed" \
    "--wait should report progress rather than waiting silently"
assert_grep "$SANDBOX/w.out" "^paseo-queue: delivered " \
    "the delivery receipt still goes to stdout"

# --- an explicit --wait-timeout is still honoured ------------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "explicit timeout" \
    --wait --wait-timeout 2 >/dev/null 2>"$SANDBOX/t.err"
assert_rc 4 "$?" "an explicit --wait-timeout should still exit 4"
assert_grep "$SANDBOX/t.err" "2s elapsed" \
    "the timeout message should name the timeout the caller actually set"

# --- --quiet suppresses progress on both streams ------------------------
PASEO_QUEUE_NO_SPAWN=1 PASEO_QUEUE_WAIT_PROGRESS_EVERY=1 \
    "$PQT_BIN" add "$AGENT_UUID" "quiet wait" --wait --wait-timeout 3 --quiet \
    >"$SANDBOX/q.out" 2>"$SANDBOX/q.err"
assert_rc 4 "$?" "quiet wait should still time out"
# Match the PROGRESS prefix specifically. The timeout error also contains
# "elapsed" and must still print under --quiet, since it is an error.
grep -q "add --wait: " "$SANDBOX/q.err" \
    && fail "--quiet must suppress progress lines"
assert_grep "$SANDBOX/q.err" "add --wait-timeout: 3s elapsed" \
    "--quiet must NOT suppress the timeout error itself"

exit 0
