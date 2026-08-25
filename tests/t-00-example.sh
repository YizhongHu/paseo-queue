#!/bin/sh
# tests/t-00-example.sh: proves the harness itself works end to end --
# seeds one idle mock agent, enqueues a message with dispatcher auto-spawn
# disabled, drives the dispatcher manually in the foreground (so this test
# stays fully synchronous), and asserts the message was delivered exactly
# once with a matching checksum and that the dispatch log recorded the
# expected lifecycle events.
#
# Not part of the t-01..t-13 test matrix (tests/mock/paseo's header comment
# and the design plan's "Test matrix" section) -- this is the harness's own
# smoke test.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="11111111-2222-3333-4444-555555555555"
AGENT_NAME="t00-agent"

seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "hello from t-00"
assert_rc 0 "$?" "add should enqueue and return immediately"

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

msgfile=""
for f in "$dp_dir/pending"/*.msg; do
    [ -e "$f" ] || continue
    msgfile="${f##*/}"
done
[ -n "$msgfile" ] || fail "expected exactly one pending message after add"

# Drive the dispatcher directly in the foreground (PASEO_QUEUE_NO_SPAWN=1
# above prevented `add` from auto-spawning it). The agent is idle with no
# pending permissions and send.script is absent, so the mock's
# missing/exhausted default fires: status flips running->idle and the send
# succeeds (rc=0). With no further arrivals, PASEO_QUEUE_LINGER=1s (set by
# setup()) makes this return on its own well within a normal test timeout.
"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "_dispatch should exit cleanly once its queue drains"

[ -e "$dp_dir/sent/$msgfile" ] || fail "delivered message not found in sent/: $msgfile"
[ -e "$dp_dir/pending/$msgfile" ] && fail "delivered message should have left pending/: $msgfile"

assert_eq "$(mock_send_count)" "1" "send.log should record exactly one delivery"

send_log_line="$(cat "$MOCK_DIR/send.log")"
logged_uuid="$(printf '%s' "$send_log_line" | cut -f1)"
logged_cksum="$(printf '%s' "$send_log_line" | cut -f2)"
logged_seq="$(printf '%s' "$send_log_line" | cut -f3)"

assert_eq "$logged_uuid" "$AGENT_UUID" "send.log uuid field should match the target agent"
assert_eq "$logged_seq" "1" "send.log seq field should be 1 for the first delivery"

expected_cksum="$(cksum < "$dp_dir/sent/$msgfile" | cut -d' ' -f1)"
assert_eq "$logged_cksum" "$expected_cksum" "send.log cksum should match the delivered file's checksum"

[ -e "$MOCK_DIR/sent.d/001" ] || fail "expected a verbatim delivered-prompt copy at sent.d/001"

dp_log="$dp_dir/dispatch.log"
assert_grep "$dp_log" "START" "dispatch.log should record dispatcher START"
assert_grep "$dp_log" "SEND-OK" "dispatch.log should record a successful send"
assert_grep "$dp_log" "EXIT" "dispatch.log should record dispatcher EXIT"

exit 0
