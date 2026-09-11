#!/bin/sh
# tests/t-27-interrupt-no-wait.sh: an interrupt must not block its caller on
# the recipient's processing time.
#
# `paseo send` genuinely interrupts a running agent -- measured directly: a
# probe agent occupied in a 100-second shell loop acknowledged a sent message
# 6 seconds after it was issued, 74 seconds before its loop would have ended,
# and reported "it arrived while step 2 was still running". Delivery was never
# the problem.
#
# The problem was the CALLER. Without --no-wait, `paseo send` does not return
# until the agent has finished PROCESSING the message: median 59s and up to
# 605s across 2833 real deliveries. So an interrupt that had already landed in
# 6 seconds left its sender blocked for minutes, and a real orchestrator
# concluded from that silence that its messages had never been delivered --
# they had, and the queue had the INTERRUPT-OK records to prove it.
#
# Pinned here: the interrupt path passes --no-wait, and the DISPATCHER path
# deliberately does not, because its FIFO one-at-a-time guarantee depends on
# knowing the previous message finished before starting the next.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000027-0000-0000-0000-000000000027"
seed_agent "$AGENT_UUID" "t27-agent" idle 0 0

send_argv() {
    # every `paseo send ...` argv line recorded by the mock
    # calls.log lines START with the subcommand, tab-separated argv.
    grep "^send	" "$MOCK_DIR/calls.log" 2>/dev/null || true
}

# --- the interrupt path passes --no-wait --------------------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "interrupt probe" \
    --interrupt --quiet
assert_rc 0 "$?" "the interrupt should succeed"

t27_sends="$(send_argv | wc -l | tr -d ' ')"
assert_eq "$t27_sends" "1" "exactly one send should have been made"
send_argv | grep -q -- "--no-wait" \
    || fail "the interrupt path must pass --no-wait so the caller is not blocked on processing"

# --- the dispatcher path deliberately does NOT --------------------------
: > "$MOCK_DIR/calls.log"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "queued probe" --quiet
assert_rc 0 "$?" "the queued add should succeed"
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
assert_rc 0 "$?" "the dispatcher should deliver"

t27_dsends="$(send_argv | wc -l | tr -d ' ')"
assert_eq "$t27_dsends" "1" "the dispatcher should have made exactly one send"
send_argv | grep -q -- "--no-wait" \
    && fail "the dispatcher must NOT use --no-wait: FIFO one-at-a-time depends on knowing the previous send completed"

# --- and the interrupt still behaves correctly otherwise ---------------
# Delivered exactly once, filed in sent/, not re-delivered by a dispatcher.
: > "$MOCK_DIR/calls.log"
dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "third probe" \
    --interrupt --quiet
assert_rc 0 "$?" "the second interrupt should succeed"

t27_pending=0
for t27_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t27_f" ] || continue
    t27_pending=$((t27_pending + 1))
done
assert_eq "$t27_pending" "0" "an interrupted message must not remain pending"

"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
assert_eq "$(send_argv | wc -l | tr -d ' ')" "1" \
    "a dispatcher run after the interrupt must not re-send it"

exit 0
