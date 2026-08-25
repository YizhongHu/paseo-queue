#!/bin/sh
# tests/t-04-stale-lock.sh: hand-plants lock/ with the pid of an already-
# reaped process (a real pid guaranteed dead: spawned, then `wait`-ed for),
# then invokes `drain` (the real spawn path). The dispatcher must detect the
# stale lock, steal it (STEAL logged), and go on to deliver the pending
# message.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000004-0000-0000-0000-000000000004"
AGENT_NAME="t04-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"
mkdir -p "$dp_dir/pending" "$dp_dir/sent" "$dp_dir/failed" "$dp_dir/tmp"

# Produce a pid that is guaranteed to be dead: spawn a trivial subshell,
# capture its pid, then `wait` for it to fully exit (reaping it).
( : ) &
t04_dead_pid=$!
wait "$t04_dead_pid" 2>/dev/null

mkdir -p "$dp_dir/lock"
printf '%s\n' "$t04_dead_pid" > "$dp_dir/lock/pid"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "stale-lock-message"
assert_rc 0 "$?" "add should enqueue behind the stale lock"

t04_msgname=""
for t04_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t04_f" ] || continue
    t04_msgname="${t04_f##*/}"
done
[ -n "$t04_msgname" ] || fail "expected exactly one pending message before drain"

"$PQT_BIN" drain "$AGENT_UUID"
assert_rc 0 "$?" "drain should exit 0"

wait_until "[ -e \"$dp_dir/sent/$t04_msgname\" ]" 10

assert_grep "$dp_dir/dispatch.log" "STEAL" "dispatcher should log STEAL for the stale lock"
[ -e "$dp_dir/pending/$t04_msgname" ] && fail "message should have left pending/ after stale-lock steal + delivery"
assert_eq "$(mock_send_count)" "1" "message should have been delivered exactly once"

exit 0
