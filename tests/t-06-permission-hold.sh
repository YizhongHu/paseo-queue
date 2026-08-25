#!/bin/sh
# tests/t-06-permission-hold.sh: agent has one pending permission (nperms=1)
# and wait.script returns instantly (no `after=` delay) on every call, so
# the only thing pacing the dispatcher's hold loop is its own gating logic
# (never attempt send() while nperms>0). Verifies: no send call happens
# across at least 3 poll cycles, HOLD-PERM is logged, state=holding-
# permission, and once nperms drops to 0 the message is delivered.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000006-0000-0000-0000-000000000006"
AGENT_NAME="t06-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 1

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# set_nperms <status> <nperms> -- test-local helper: agents.tsv here holds
# exactly one row, so it can just be rewritten wholesale in the same format
# seed_agent/mock_lookup_agent use (uuid, shortId, name, status, archived,
# nperms), tab-separated.
set_nperms() {
    sn_status="$1"; sn_nperms="$2"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$AGENT_UUID" "$(printf '%.7s' "$AGENT_UUID")" "$AGENT_NAME" "$sn_status" 0 "$sn_nperms" \
        > "$MOCK_DIR/agents.tsv"
}

# wait.script: several instantly-returning "permission still pending" lines
# so the hold loop doesn't fall through to the mock's exhausted-script
# default (which sleeps 1s per call) before we've observed >=3 poll cycles.
mock_set_wait_script \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission" \
    "after=0 result=permission"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "held-by-permission"
assert_rc 0 "$?" "add should enqueue the message"

"$PQT_BIN" _dispatch "$AGENT_UUID" &
t06_pid=$!

wait_until "[ \"\$(cut -f1 \"$MOCK_DIR/calls.log\" | grep -c '^wait\$')\" -ge 3 ]" 10

# nperms is still 1 (we have not touched agents.tsv since seeding it), so
# these assertions are race-free: no send has been attempted, nor will one
# be, until we explicitly release the permission below.
t06_send_calls="$(cut -f1 "$MOCK_DIR/calls.log" | grep -c '^send$')"
assert_eq "$t06_send_calls" "0" "no send call should happen while a permission is pending"

t06_state="$(cat "$dp_dir/state" 2>/dev/null)"
assert_eq "$t06_state" "holding-permission" "dispatcher state should be holding-permission"

assert_grep "$dp_dir/dispatch.log" "HOLD-PERM" "dispatcher should log HOLD-PERM while nperms>0"

# Release the permission: the dispatcher's next poll should see nperms=0
# and proceed to deliver the message.
set_nperms idle 0

wait_until "[ -e \"$dp_dir/sent\" ] && [ \"\$(ls -1 \"$dp_dir/sent\" 2>/dev/null | wc -l | tr -d ' ')\" -ge 1 ]" 15

wait "$t06_pid"
assert_rc 0 "$?" "dispatcher should exit cleanly once the message is delivered"

t06_pending=0
for t06_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t06_f" ] || continue
    t06_pending=$((t06_pending + 1))
done
assert_eq "$t06_pending" "0" "message should have left pending/ after delivery"
assert_eq "$(mock_send_count)" "1" "exactly one delivery should have happened"

exit 0
