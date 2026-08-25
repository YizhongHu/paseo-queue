#!/bin/sh
# tests/t-05-spawn-race.sh: exercises the spawn-race protocol (plan's
# "Design (hardened spec)" section) end to end via the real spawn path (no
# PASEO_QUEUE_NO_SPAWN):
#   (a) adding a second message while the dispatcher is inside its
#       PASEO_QUEUE_LINGER window must resume the SAME dispatcher (exactly
#       one START logged), not spawn a competing one.
#   (b) 20 iterations of "add immediately after the previous dispatcher
#       exited" (PASEO_QUEUE_LINGER=0, so each dispatcher tries to exit the
#       instant its queue empties) must never strand a pending message: the
#       release+recheck+REACQUIRE/YIELD dance must guarantee every message
#       eventually gets a live dispatcher and a matching SEND-OK.
# Uses two distinct agents (one per scenario) inside a single sandbox so
# both scenarios share one setup/teardown.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

# wait_for <cond> <timeout> -- same-shell polling loop (unlike wait_until,
# which forks a fresh `sh -c` that cannot see functions/vars sourced from
# common.sh, e.g. mock_send_count). Evaluates <cond> via `eval` once per
# second until it's true or <timeout> elapses.
wait_for() {
    wf_cond="$1"; wf_timeout="$2"
    wf_elapsed=0
    while [ "$wf_elapsed" -lt "$wf_timeout" ]; do
        eval "$wf_cond" && return 0
        sleep 1
        wf_elapsed=$((wf_elapsed + 1))
    done
    return 1
}

# --- Part (a): add-during-linger resumes the same dispatcher -------------

AGENT_A="a0000005-0000-0000-0000-00000000000a"
seed_agent "$AGENT_A" "t05a-agent" idle 0 0
dpA_dir="$PASEO_QUEUE_HOME/$AGENT_A"

export PASEO_QUEUE_LINGER=3

"$PQT_BIN" add "$AGENT_A" "race-a-msg-1"
assert_rc 0 "$?" "part (a): first add should return immediately"

# Wait until the dispatcher has actually entered its linger window (logged
# right before the poll-for-arrivals loop) before adding the second message,
# so we know for certain we are inside the race window rather than racing
# the dispatcher's own startup.
wait_until "grep -q LINGER \"$dpA_dir/dispatch.log\"" 10

"$PQT_BIN" add "$AGENT_A" "race-a-msg-2"
assert_rc 0 "$?" "part (a): second add (during linger) should return immediately"

wait_for '[ "$(ls -1 "'"$dpA_dir"'/sent" 2>/dev/null | wc -l | tr -d " ")" -ge 2 ]' 10 \
    || fail "part (a): both messages should eventually be delivered"

t05a_starts="$(grep -c '\] START ' "$dpA_dir/dispatch.log")"
assert_eq "$t05a_starts" "1" "part (a): exactly one START should be logged (the second add must resume, not restart, the dispatcher)"

t05a_skips="$(grep -c '\] SKIP ' "$dpA_dir/dispatch.log")"
[ "$t05a_skips" -ge 1 ] || fail "part (a): expected at least one SKIP from the second add's own speculative spawn"

t05a_pending=0
for t05a_f in "$dpA_dir/pending"/*.msg; do
    [ -e "$t05a_f" ] || continue
    t05a_pending=$((t05a_pending + 1))
done
assert_eq "$t05a_pending" "0" "part (a): no stranded pending messages"

# --- Part (b): 20x add-immediately-after-previous-dispatcher-EXIT --------

AGENT_B="a0000005-0000-0000-0000-00000000000b"
seed_agent "$AGENT_B" "t05b-agent" idle 0 0
dpB_dir="$PASEO_QUEUE_HOME/$AGENT_B"

export PASEO_QUEUE_LINGER=0

t05b_i=1
while [ "$t05b_i" -le 20 ]; do
    "$PQT_BIN" add "$AGENT_B" "race-b-msg-$t05b_i"
    assert_rc 0 "$?" "part (b): add #$t05b_i should return immediately"
    t05b_i=$((t05b_i + 1))
done

wait_for '[ -f "'"$dpB_dir"'/dispatch.log" ] && [ "$(grep -c SEND-OK "'"$dpB_dir"'/dispatch.log")" -ge 20 ]' 30 \
    || fail "part (b): all 20 messages should eventually be delivered"

t05b_pending=0
for t05b_f in "$dpB_dir/pending"/*.msg; do
    [ -e "$t05b_f" ] || continue
    t05b_pending=$((t05b_pending + 1))
done
assert_eq "$t05b_pending" "0" "part (b): zero stranded pending messages after settle"

t05b_sendok="$(grep -c 'SEND-OK' "$dpB_dir/dispatch.log")"
assert_eq "$t05b_sendok" "20" "part (b): expected exactly 20 SEND-OK events, one per enqueued message"

exit 0
