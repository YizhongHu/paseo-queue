#!/bin/sh
# tests/t-08-send-retry-transient.sh: simulates a transient daemon outage
# (the mock's global `down` toggle, which fails *every* subcommand including
# `paseo inspect`) that resolves on its own after a few seconds. This drives
# the dispatcher's transient-daemon path (dp_inspect_classify -> "daemon"),
# which must survive the outage window (state=daemon-retry, no FATAL) and
# go on to deliver the message once the toggle is removed, without ever
# touching failed/.
#
# Getting a real multi-second backoff window requires
# PASEO_QUEUE_BACKOFF_SCALE=1 (the suite's default fast-knob of 0 collapses
# the daemon backoff schedule to instant, which would exhaust
# PASEO_QUEUE_DAEMON_RETRIES before the outage window even elapses) --
# scoped to this one dispatcher invocation only.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000008-0000-0000-0000-000000000008"
AGENT_NAME="t08-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "daemon-down-message"
assert_rc 0 "$?" "add should enqueue before the outage begins"

: > "$MOCK_DIR/down"

PASEO_QUEUE_BACKOFF_SCALE=1 "$PQT_BIN" _dispatch "$AGENT_UUID" &
t08_pid=$!

wait_until "[ -f \"$dp_dir/state\" ] && [ \"\$(cat \"$dp_dir/state\")\" = daemon-retry ]" 5

# Hold the outage for a few seconds (well inside the first daemon backoff
# window: dp_daemon_backoff(1) == 10s), then clear it -- proving recovery
# happens once connectivity returns, not because the retry budget ran out.
sleep 3
rm -f "$MOCK_DIR/down"

wait_until "[ -e \"$dp_dir/sent\" ] && [ \"\$(ls -1 \"$dp_dir/sent\" 2>/dev/null | wc -l | tr -d ' ')\" -ge 1 ]" 25

wait "$t08_pid"
assert_rc 0 "$?" "dispatcher should exit cleanly after recovering from the outage"

t08_pending=0
for t08_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t08_f" ] || continue
    t08_pending=$((t08_pending + 1))
done
assert_eq "$t08_pending" "0" "message should have left pending/ after recovery"

t08_failed=0
for t08_f in "$dp_dir/failed"/*.msg; do
    [ -e "$t08_f" ] || continue
    t08_failed=$((t08_failed + 1))
done
assert_eq "$t08_failed" "0" "nothing should have landed in failed/ from a transient daemon outage"

grep -q "FATAL" "$dp_dir/dispatch.log" && fail "dispatcher should never reach FATAL during a recoverable outage"
assert_eq "$(mock_send_count)" "1" "exactly one delivery should have happened, after recovery"

exit 0
