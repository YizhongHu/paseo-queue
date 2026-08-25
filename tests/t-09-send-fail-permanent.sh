#!/bin/sh
# tests/t-09-send-fail-permanent.sh: send.script fails 5 times in a row
# (PASEO_QUEUE_SEND_RETRIES defaults to 5) while the agent stays alive and
# idle throughout (a genuine transient-message failure per the taxonomy,
# never archived/closed). After the 5th failure the dispatcher must give up
# on this message: move it to failed/ with a .err sidecar (rc + stderr
# tail), log FATAL, halt (not skip -- a second, untouched pending message
# proves later messages are never reordered ahead of a stuck one), exit 1,
# and release its lock.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000009-0000-0000-0000-000000000009"
AGENT_NAME="t09-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "will-fail-message"
assert_rc 0 "$?" "add #1 should enqueue"
t09_msg1=""
for t09_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t09_f" ] || continue
    t09_msg1="${t09_f##*/}"
done
[ -n "$t09_msg1" ] || fail "expected message #1 to be pending"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "second-untouched-message"
assert_rc 0 "$?" "add #2 should enqueue"

t09_pending=0
t09_msg2=""
for t09_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t09_f" ] || continue
    t09_pending=$((t09_pending + 1))
    [ "${t09_f##*/}" = "$t09_msg1" ] || t09_msg2="${t09_f##*/}"
done
assert_eq "$t09_pending" "2" "expected 2 pending messages before dispatch"
[ -n "$t09_msg2" ] || fail "expected to identify the second message's filename"

mock_set_send_script \
    "rc=1 err=boom-attempt-1" \
    "rc=1 err=boom-attempt-2" \
    "rc=1 err=boom-attempt-3" \
    "rc=1 err=boom-attempt-4" \
    "rc=1 err=boom-attempt-5"

"$PQT_BIN" _dispatch "$AGENT_UUID"
t09_rc=$?
assert_rc 1 "$t09_rc" "dispatcher should exit 1 after exhausting the send-retry budget"

[ -e "$dp_dir/failed/$t09_msg1" ] || fail "message #1 should have moved to failed/"
[ -e "$dp_dir/pending/$t09_msg1" ] && fail "message #1 should have left pending/"
[ -e "$dp_dir/pending/$t09_msg2" ] || fail "message #2 should remain untouched in pending/ (halt, don't skip)"
[ -e "$dp_dir/sent/$t09_msg2" ] && fail "message #2 must never have been attempted"

t09_err="$dp_dir/failed/$t09_msg1.err"
[ -e "$t09_err" ] || fail "expected a .err sidecar for the permanently-failed message"
assert_grep "$t09_err" "rc=1" ".err sidecar should record the failing rc"
assert_grep "$t09_err" "boom-attempt-5" ".err sidecar should record the final attempt's stderr"

assert_grep "$dp_dir/dispatch.log" "FATAL" "dispatcher should log FATAL"
assert_grep "$dp_dir/dispatch.log" "reason=message-failed" "FATAL should record reason=message-failed"

t09_sendfail_count="$(grep -c 'SEND-FAIL' "$dp_dir/dispatch.log")"
assert_eq "$t09_sendfail_count" "5" "expected 5 SEND-FAIL events, one per attempt"

t09_retry_count="$(grep -c 'RETRY' "$dp_dir/dispatch.log")"
assert_eq "$t09_retry_count" "4" "expected 4 RETRY events (attempts 1-4; the 5th halts instead of retrying)"

t09_state="$(cat "$dp_dir/state" 2>/dev/null)"
assert_eq "$t09_state" "halted-failed" "dispatcher state should be halted-failed"

[ -d "$dp_dir/lock" ] && fail "lock should be released after halting on permanent send failure"

# Agent status should never have been mutated by this scenario (proves this
# was a genuine transient-message failure, not an accidental close).
t09_final_status="$(mock_agent_status "$AGENT_UUID")"
assert_eq "$t09_final_status" "idle" "agent should have stayed idle throughout the send-retry failures"

exit 0
