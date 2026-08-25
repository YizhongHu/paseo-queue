#!/bin/sh
# tests/t-03-lock-exclusivity.sh: backgrounds one _dispatch that gets stuck
# in a scripted long `paseo wait` (agent status=running, wait.script sleeps
# a few seconds before releasing), then invokes a second _dispatch for the
# same agent in the foreground while the first still holds the lock.
# Verifies the second invocation exits 0 fast (it must SKIP, not block or
# steal), logs SKIP, and leaves lock/pid unchanged.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000003-0000-0000-0000-000000000003"
AGENT_NAME="t03-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" running 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# The held dispatcher needs a message to work on so it reaches the
# busy/waiting branch (an empty queue would just linger and exit instead).
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "held-by-long-wait"
assert_rc 0 "$?" "add should enqueue the message the first dispatcher will hold"

# wait.script: sleeps 3s (simulating a long-running busy period) before
# reporting idle and flipping the agent's status so the first dispatcher can
# eventually finish.
mock_set_wait_script "after=3 result=idle set_status=idle"

"$PQT_BIN" _dispatch "$AGENT_UUID" &
t03_first_pid=$!

wait_until "[ -f \"$dp_dir/lock/pid\" ]" 5
t03_held_pid="$(cat "$dp_dir/lock/pid")"
[ -n "$t03_held_pid" ] || fail "first dispatcher should have written lock/pid"

t03_t0="$(date +%s)"
"$PQT_BIN" _dispatch "$AGENT_UUID"
t03_second_rc=$?
t03_t1="$(date +%s)"
assert_rc 0 "$t03_second_rc" "second _dispatch invocation should exit 0 (SKIP)"

t03_elapsed=$((t03_t1 - t03_t0))
[ "$t03_elapsed" -le 2 ] || fail "second _dispatch should exit fast, took ${t03_elapsed}s"

assert_grep "$dp_dir/dispatch.log" "SKIP" "second invocation should log SKIP"

t03_after_pid="$(cat "$dp_dir/lock/pid")"
assert_eq "$t03_after_pid" "$t03_held_pid" "lock/pid must be unchanged by the SKIPped second dispatch"

# Let the first (held) dispatcher finish its work: it will unblock from the
# 3s scripted wait, see the agent idle, deliver the message, linger briefly,
# and exit.
wait "$t03_first_pid"
t03_first_rc=$?
assert_rc 0 "$t03_first_rc" "first (held) dispatcher should eventually exit cleanly"

t03_sent=0
for t03_f in "$dp_dir/sent"/*.msg; do
    [ -e "$t03_f" ] || continue
    t03_sent=$((t03_sent + 1))
done
assert_eq "$t03_sent" "1" "the held message should eventually be delivered by the first dispatcher"

exit 0
