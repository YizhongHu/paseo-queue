#!/bin/sh
# tests/t-30-urgency-and-position.sh: the two axes must stay independent and
# unambiguous.
#
# AXIS 1, urgency -- how the message is DELIVERED:
#   no flag      routine; delivered FIFO once the agent is idle
#   --priority   jump the backlog, arrive mid-work, agent carries on
#   --interrupt  cancel the current turn, then deliver
# The last two are mutually exclusive: a caller states one intent, not both.
#
# AXIS 2, blocking -- how the SENDER waits:
#   default            returns immediately
#   --wait             blocks until resolved, no deadline
#   --wait-timeout N   bounded
# Axis 2 is meaningless for the immediate-delivery flags, which have already
# delivered by the time they return.
#
# Also pinned: the enqueue receipt reports queue POSITION, so a sender can see
# where it landed instead of running `ls` to guess.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000030-0000-0000-0000-000000000030"
seed_agent "$AGENT_UUID" "t30-agent" idle 0 0

# --- the two urgency flags are mutually exclusive -----------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "both" \
    --priority --interrupt >"$SANDBOX/both.out" 2>"$SANDBOX/both.err"
assert_rc 1 "$?" "--priority with --interrupt must be rejected"
assert_grep "$SANDBOX/both.err" "mutually exclusive" \
    "the rejection should say they are mutually exclusive"
assert_grep "$SANDBOX/both.err" "cancels its current turn" \
    "the rejection should explain the difference, not just refuse"
[ ! -s "$SANDBOX/both.out" ] || fail "a rejected add must not print a receipt"

t30_pending=0
for t30_f in "$PASEO_QUEUE_HOME/$AGENT_UUID/pending"/*.msg; do
    [ -e "$t30_f" ] || continue
    t30_pending=$((t30_pending + 1))
done
assert_eq "$t30_pending" "0" "a rejected add must not enqueue anything"

# --- order of the flags must not change the outcome ---------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "both reversed" \
    --interrupt --priority >/dev/null 2>"$SANDBOX/rev.err"
assert_rc 1 "$?" "the rejection must not depend on flag order"
assert_grep "$SANDBOX/rev.err" "mutually exclusive" \
    "reversed order should give the same rejection"

# --- axis 2 is rejected for immediate delivery --------------------------
for t30_flag in --priority --interrupt; do
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "with wait" \
        "$t30_flag" --wait >/dev/null 2>"$SANDBOX/w.err"
    assert_rc 1 "$?" "$t30_flag with --wait should be rejected"
    assert_grep "$SANDBOX/w.err" "redundant" \
        "$t30_flag with --wait should be called redundant"
done

# --- queue position, the "where am I" signal ----------------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "first" >"$SANDBOX/q1.out" 2>&1
assert_rc 0 "$?" "first queued add should succeed"
grep -q "ahead" "$SANDBOX/q1.out" \
    && fail "the first message has nothing ahead of it and must not claim a position"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "second" >"$SANDBOX/q2.out" 2>&1
assert_grep "$SANDBOX/q2.out" "(target: idle, 1 ahead)" \
    "the second message should report one ahead of it"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "third" >"$SANDBOX/q3.out" 2>&1
assert_grep "$SANDBOX/q3.out" "(target: idle, 2 ahead)" \
    "the third message should report two ahead of it"

# The path stays the last field even with the position annotation present.
t30_last="$(awk '{print $NF}' "$SANDBOX/q3.out")"
case "$t30_last" in
    pending/*.msg) : ;;
    *) fail "the pending/ path must stay the last field, got [$t30_last]" ;;
esac

# --- --priority reports no position, because it jumps the backlog -------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "jumper" --priority \
    >"$SANDBOX/p.out" 2>&1
assert_rc 0 "$?" "--priority should succeed with a backlog present"
grep -q "ahead" "$SANDBOX/p.out" \
    && fail "--priority jumps the backlog and must not report a position in it"

exit 0
