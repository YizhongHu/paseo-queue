#!/bin/sh
# tests/t-07-closed-agent.sh: 3 messages queued; the second delivery attempt
# fails and simultaneously flips the agent to status=closed (send.script
# line 2). The dispatcher's failure-taxonomy follow-up inspect must
# classify this as permanent/closed (not transient), HALT rather than
# retry-then-fail, and leave both undelivered messages sitting untouched in
# pending/ (message 1, already sent before the halt, stays in sent/).
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000007-0000-0000-0000-000000000007"
AGENT_NAME="t07-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "closed-agent-msg-1"
assert_rc 0 "$?" "add #1 should enqueue"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "closed-agent-msg-2"
assert_rc 0 "$?" "add #2 should enqueue"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "closed-agent-msg-3"
assert_rc 0 "$?" "add #3 should enqueue"

t07_pending=0
for t07_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t07_f" ] || continue
    t07_pending=$((t07_pending + 1))
done
assert_eq "$t07_pending" "3" "expected 3 pending messages before dispatch"

mock_set_send_script "rc=0" "rc=1 set_status=closed" "rc=0"

"$PQT_BIN" _dispatch "$AGENT_UUID"
t07_rc=$?
assert_rc 0 "$t07_rc" "dispatcher should exit 0 when halting on a closed agent"

t07_sent=0
for t07_f in "$dp_dir/sent"/*.msg; do
    [ -e "$t07_f" ] || continue
    t07_sent=$((t07_sent + 1))
done
assert_eq "$t07_sent" "1" "exactly the first message should be in sent/"

t07_pending_after=0
for t07_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t07_f" ] || continue
    t07_pending_after=$((t07_pending_after + 1))
done
assert_eq "$t07_pending_after" "2" "the two undelivered messages should remain in pending/"

t07_failed=0
for t07_f in "$dp_dir/failed"/*.msg; do
    [ -e "$t07_f" ] || continue
    t07_failed=$((t07_failed + 1))
done
assert_eq "$t07_failed" "0" "nothing should have moved to failed/ (closed is a halt, not a permanent-message failure)"

assert_grep "$dp_dir/dispatch.log" "HALT" "dispatcher should log HALT"
assert_grep "$dp_dir/dispatch.log" "reason=closed" "HALT should record reason=closed"

t07_state="$(cat "$dp_dir/state" 2>/dev/null)"
assert_eq "$t07_state" "halted-closed" "dispatcher state should be halted-closed"

[ -d "$dp_dir/lock" ] && fail "lock should be released after halting on a closed agent"

exit 0
