#!/bin/sh
# tests/t-13-delivery-modes.sh: covers the four delivery-mode contracts from
# the design plan, one scenario per dedicated agent (run strictly in
# sequence -- wait.script/send.script are global to the sandbox, so each
# scenario's dispatcher is confirmed fully wound down before the next
# begins):
#   (A) default `add` returns before delivery happens (fire-and-forget).
#   (B) `add --wait` exits 0 only once the message is actually in sent/.
#   (C) `add --wait --wait-timeout 3` against a permanently-busy agent
#       exits 4, message stays pending.
#   (D) `add --wait` against a queue that halts (closed agent) exits 1,
#       message stays pending.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

# --- Scenario A: default add returns before delivery ---------------------

AGENT_A="a0000013-0000-0000-0000-00000000000a"
seed_agent "$AGENT_A" "t13a-agent" running 0 0
dpA_dir="$PASEO_QUEUE_HOME/$AGENT_A"

# The agent is busy for 2s (mock sleeps 2s before flipping it idle), so the
# dispatcher cannot deliver immediately -- proving `add` itself returns well
# before that window elapses.
mock_set_wait_script "after=2 result=idle set_status=idle"

t13a_t0="$(date +%s)"
"$PQT_BIN" add "$AGENT_A" "delivery-mode-default"
t13a_add_rc=$?
t13a_t1="$(date +%s)"
assert_rc 0 "$t13a_add_rc" "scenario A: default add should return 0"

t13a_elapsed=$((t13a_t1 - t13a_t0))
[ "$t13a_elapsed" -le 1 ] || fail "scenario A: default add should return near-instantly, took ${t13a_elapsed}s"

t13a_msg=""
for t13a_f in "$dpA_dir/pending"/*.msg; do
    [ -e "$t13a_f" ] || continue
    t13a_msg="${t13a_f##*/}"
done
[ -n "$t13a_msg" ] || fail "scenario A: expected the message to still be pending immediately after add returns"
[ -e "$dpA_dir/sent/$t13a_msg" ] && fail "scenario A: message must not already be sent at the moment add returns"

wait_until "[ -e \"$dpA_dir/sent/$t13a_msg\" ]" 10
wait_until "grep -q EXIT \"$dpA_dir/dispatch.log\"" 10

# --- Scenario B: --wait exits 0 only after sent/ --------------------------

AGENT_B="a0000013-0000-0000-0000-00000000000b"
seed_agent "$AGENT_B" "t13b-agent" idle 0 0
dpB_dir="$PASEO_QUEUE_HOME/$AGENT_B"

"$PQT_BIN" add "$AGENT_B" "delivery-mode-wait" --wait
assert_rc 0 "$?" "scenario B: --wait should exit 0 once delivered"

t13b_sent=0
for t13b_f in "$dpB_dir/sent"/*.msg; do
    [ -e "$t13b_f" ] || continue
    t13b_sent=$((t13b_sent + 1))
done
assert_eq "$t13b_sent" "1" "scenario B: message should be in sent/ by the time --wait returns"

t13b_pending=0
for t13b_f in "$dpB_dir/pending"/*.msg; do
    [ -e "$t13b_f" ] || continue
    t13b_pending=$((t13b_pending + 1))
done
assert_eq "$t13b_pending" "0" "scenario B: nothing should remain pending"

wait_until "grep -q EXIT \"$dpB_dir/dispatch.log\"" 10

# --- Scenario C: --wait --wait-timeout with a permanently-busy agent -----

AGENT_C="a0000013-0000-0000-0000-00000000000c"
seed_agent "$AGENT_C" "t13c-agent" running 0 0
dpC_dir="$PASEO_QUEUE_HOME/$AGENT_C"

# No wait.script entries remain (scenario A's one line was already consumed
# by scenario A's dispatcher, which we confirmed fully exited above), so
# mock_wait falls into its exhausted/missing default: sleep 1s, report the
# agent's *current* status unchanged. Nothing ever flips this agent's
# status away from "running", so it is permanently busy for this scenario.
t13c_t0="$(date +%s)"
"$PQT_BIN" add "$AGENT_C" "delivery-mode-timeout" --wait --wait-timeout 3
t13c_rc=$?
t13c_t1="$(date +%s)"
assert_rc 4 "$t13c_rc" "scenario C: --wait-timeout should exit 4 against a permanently-busy agent"

t13c_elapsed=$((t13c_t1 - t13c_t0))
[ "$t13c_elapsed" -ge 3 ] || fail "scenario C: --wait-timeout 3 should not return before 3s elapsed (took ${t13c_elapsed}s)"
[ "$t13c_elapsed" -le 8 ] || fail "scenario C: --wait-timeout 3 took suspiciously long (${t13c_elapsed}s)"

t13c_pending=0
for t13c_f in "$dpC_dir/pending"/*.msg; do
    [ -e "$t13c_f" ] || continue
    t13c_pending=$((t13c_pending + 1))
done
assert_eq "$t13c_pending" "1" "scenario C: message should remain queued after the wait times out"

t13c_sent=0
for t13c_f in "$dpC_dir/sent"/*.msg; do
    [ -e "$t13c_f" ] || continue
    t13c_sent=$((t13c_sent + 1))
done
assert_eq "$t13c_sent" "0" "scenario C: nothing should have been delivered"

# Tidy up: agent C's dispatcher is still alive (permanently busy, so it
# never exits on its own) -- stop it explicitly before starting scenario D
# so the two scenarios' dispatchers never overlap.
"$PQT_BIN" stop "$AGENT_C"
assert_rc 0 "$?" "stop should signal agent C's still-live dispatcher"
wait_until "grep -q EXIT \"$dpC_dir/dispatch.log\"" 10

# --- Scenario D: --wait on a queue that halts (closed agent) -------------

AGENT_D="a0000013-0000-0000-0000-00000000000d"
seed_agent "$AGENT_D" "t13d-agent" idle 0 0
dpD_dir="$PASEO_QUEUE_HOME/$AGENT_D"

mock_set_send_script "rc=1 set_status=closed"

"$PQT_BIN" add "$AGENT_D" "delivery-mode-halt" --wait
t13d_rc=$?
assert_rc 1 "$t13d_rc" "scenario D: --wait should exit 1 once the dispatcher halts on a closed agent"

t13d_pending=0
for t13d_f in "$dpD_dir/pending"/*.msg; do
    [ -e "$t13d_f" ] || continue
    t13d_pending=$((t13d_pending + 1))
done
assert_eq "$t13d_pending" "1" "scenario D: message should remain queued after the halt"

t13d_sent=0
for t13d_f in "$dpD_dir/sent"/*.msg; do
    [ -e "$t13d_f" ] || continue
    t13d_sent=$((t13d_sent + 1))
done
assert_eq "$t13d_sent" "0" "scenario D: nothing should have been delivered"

exit 0
