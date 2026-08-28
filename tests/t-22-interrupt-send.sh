#!/bin/sh
# tests/t-22-interrupt-send.sh: `add --interrupt` delivers now, bypassing the
# idle/permission gate, and the message must never be delivered a SECOND time.
#
# Why this exists. The documented way to interrupt an agent was a bare
# `paseo send`, which the queue knows nothing about. If the same message had
# also been queued, the dispatcher delivered it AGAIN later -- a duplicate
# that the sender could not see coming. Routing the interrupt through the
# queue records it, delivers it once, and files it in sent/, so no dispatcher
# will ever pick it up again. That no-second-delivery property is the point of
# the feature and the core assertion here.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

# status=running: an ordinary `add` would hold in the WAIT-BUSY loop here, so
# delivery in this test can only have come from the interrupt path.
AGENT_UUID="a0000022-0000-0000-0000-000000000022"
seed_agent "$AGENT_UUID" "t22-agent" running 0 0
dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

mock_send_count() {
    msc=0
    for msc_f in "$MOCK_DIR/sent.d"/*; do
        [ -e "$msc_f" ] || continue
        msc=$((msc + 1))
    done
    printf '%s\n' "$msc"
}

# --- interrupt delivers to a BUSY agent ---------------------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "urgent while busy" \
    --interrupt >"$SANDBOX/int.out" 2>"$SANDBOX/int.err"
assert_rc 0 "$?" "--interrupt should deliver even though the agent is busy"

assert_grep "$SANDBOX/int.out" "^paseo-queue: enqueued a000002 pending/" \
    "--interrupt should still print the enqueue receipt"
assert_grep "$SANDBOX/int.out" "^paseo-queue: interrupted a000002 " \
    "--interrupt should report the interrupt, not a normal delivery"

assert_eq "$(mock_send_count)" "1" "the message should have been sent exactly once"

# --- and it is FILED as sent, which is what kills the duplicate ---------
t22_pending=0
for t22_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t22_f" ] || continue
    t22_pending=$((t22_pending + 1))
done
assert_eq "$t22_pending" "0" "an interrupted message must not stay in pending/"

t22_sent=0
t22_name=""
for t22_f in "$dp_dir/sent"/*.msg; do
    [ -e "$t22_f" ] || continue
    t22_sent=$((t22_sent + 1))
    t22_name="$(basename "$t22_f")"
done
assert_eq "$t22_sent" "1" "the interrupted message must be filed in sent/"

assert_grep "$dp_dir/dispatch.log" "INTERRUPT-OK msg=$t22_name" \
    "the interrupt should be recorded in the dispatch log"

# --- THE POINT: a dispatcher must not re-deliver it ---------------------
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
assert_rc 0 "$?" "a dispatcher run after an interrupt should exit cleanly"
assert_eq "$(mock_send_count)" "1" \
    "a dispatcher must NOT deliver an interrupted message a second time"

# --- --quiet silences the receipts, both streams -----------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "quiet interrupt" \
    --interrupt --quiet >"$SANDBOX/q.out" 2>"$SANDBOX/q.err"
assert_rc 0 "$?" "--interrupt --quiet should succeed"
[ ! -s "$SANDBOX/q.out" ] || fail "--interrupt --quiet must print nothing on stdout"
[ ! -s "$SANDBOX/q.err" ] || fail "--interrupt --quiet must print nothing on stderr"
assert_eq "$(mock_send_count)" "2" "the quiet interrupt should also have sent"

# --- --interrupt with --wait is rejected, not silently ignored ---------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "both" --interrupt --wait \
    >/dev/null 2>"$SANDBOX/both.err"
assert_rc 1 "$?" "--interrupt with --wait should be rejected"
assert_grep "$SANDBOX/both.err" "redundant" \
    "the rejection should explain that --wait adds nothing to an interrupt"

# --- failure degrades to a queued message rather than losing it -------
mock_set_send_script "rc=1 err=interrupt-boom"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "will fail to interrupt" \
    --interrupt >"$SANDBOX/fail.out" 2>"$SANDBOX/fail.err"
assert_rc 1 "$?" "a failed interrupt must exit non-zero: the caller did not get immediacy"
assert_grep "$SANDBOX/fail.err" "message stays queued for normal delivery" \
    "a failed interrupt should say the message is still queued"
assert_grep "$dp_dir/dispatch.log" "INTERRUPT-FAIL" \
    "a failed interrupt should be recorded in the dispatch log"

t22_pending_after=0
for t22_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t22_f" ] || continue
    t22_pending_after=$((t22_pending_after + 1))
done
assert_eq "$t22_pending_after" "1" \
    "a failed interrupt must LEAVE the message queued, never drop it"

exit 0
