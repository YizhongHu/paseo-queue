#!/bin/sh
# tests/t-29-interrupt-preempt.sh: `add --interrupt` must CANCEL the target's
# current turn before delivering; `--priority` must not.
#
# These were one flag until the distinction was made explicit. The old
# --interrupt jumped the queue and arrived mid-turn but left the agent
# running, which misled readers in both directions: an orchestrator concluded
# delivery had failed, and the maintainer expected it to stop the agent. Now:
#
#   --priority   jump the queue, arrive mid-turn, agent carries on
#   --interrupt  cancel the running turn first, then deliver
#
# --interrupt is destructive by design: work the agent had not yet reported is
# lost. That is why it is a separate flag and why its receipt differs.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

# Separate agents per case: the mock flips a target running->idle on a
# successful send, so reusing one agent would leave the second test looking
# at an idle target and silently assert the wrong thing.
PRIO_UUID="a0000029-0000-0000-0000-00000000000p"
RUNNING_UUID="a0000029-0000-0000-0000-00000000000r"
IDLE_UUID="a0000029-0000-0000-0000-00000000000i"
QUIET_UUID="a0000029-0000-0000-0000-00000000000q"
seed_agent "$PRIO_UUID" "t29-prio" running 0 0
seed_agent "$RUNNING_UUID" "t29-running" running 0 0
seed_agent "$IDLE_UUID" "t29-idle" idle 0 0
seed_agent "$QUIET_UUID" "t29-quiet" running 0 0

stop_calls() {
    # grep -c prints 0 AND exits 1 when nothing matches, so a `|| printf 0`
    # fallback would emit TWO lines. Normalize instead.
    sc_n="$(grep -c "^stop	" "$MOCK_DIR/calls.log" 2>/dev/null | head -1 | tr -d ' ')"
    [ -n "$sc_n" ] || sc_n=0
    printf '%s\n' "$sc_n"
}

# --- --priority must NOT stop the agent ---------------------------------
: > "$MOCK_DIR/calls.log"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$PRIO_UUID" "priority msg" \
    --priority >"$SANDBOX/p.out" 2>"$SANDBOX/p.err"
assert_rc 0 "$?" "--priority should succeed against a running agent"
assert_eq "$(stop_calls)" "0" "--priority must NEVER stop the agent"
assert_grep "$SANDBOX/p.out" "^paseo-queue: prioritised " \
    "--priority's receipt should read prioritised"
grep -q "interrupted" "$SANDBOX/p.out" \
    && fail "--priority must not claim to have interrupted anything"

# --- --interrupt MUST stop a running agent ------------------------------
: > "$MOCK_DIR/calls.log"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$RUNNING_UUID" "interrupt msg" \
    --interrupt >"$SANDBOX/i.out" 2>"$SANDBOX/i.err"
assert_rc 0 "$?" "--interrupt should succeed against a running agent"
assert_eq "$(stop_calls)" "1" "--interrupt must stop the agent exactly once"
assert_grep "$SANDBOX/i.out" "^paseo-queue: interrupted " \
    "--interrupt's receipt should read interrupted"
assert_grep "$SANDBOX/i.err" "running turn cancelled" \
    "--interrupt should say plainly that it cancelled a running turn"

dp_dir="$PASEO_QUEUE_HOME/$RUNNING_UUID"
assert_grep "$dp_dir/dispatch.log" "PREEMPT-STOP.*target_was=running.*turn cancelled" \
    "the log should record that a running turn was cancelled"

# --- --interrupt on an IDLE agent: still delivers, says nothing cancelled
: > "$MOCK_DIR/calls.log"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$IDLE_UUID" "interrupt idle" \
    --interrupt >"$SANDBOX/ii.out" 2>"$SANDBOX/ii.err"
assert_rc 0 "$?" "--interrupt against an idle agent should still deliver"
assert_grep "$SANDBOX/ii.err" "had no running turn to cancel" \
    "--interrupt must not claim a cancellation that did not happen"
assert_grep "$PASEO_QUEUE_HOME/$IDLE_UUID/dispatch.log" \
    "PREEMPT-STOP.*nothing running to cancel" \
    "the log should distinguish a no-op stop from a real cancellation"

# `paseo stop` exits 0 even for an agent that does not exist, so the code must
# report from the RESOLVED STATUS rather than from stop's exit code. The two
# assertions above are what pin that.

# --- both still deliver exactly once and file as sent -------------------
for t29_u in "$PRIO_UUID" "$RUNNING_UUID" "$IDLE_UUID"; do
    t29_pending=0
    for t29_f in "$PASEO_QUEUE_HOME/$t29_u/pending"/*.msg; do
        [ -e "$t29_f" ] || continue
        t29_pending=$((t29_pending + 1))
    done
    assert_eq "$t29_pending" "0" "no message should be left pending for $t29_u"
done

# --- --quiet suppresses receipts but NOT the cancellation notice --------
: > "$MOCK_DIR/calls.log"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$QUIET_UUID" "quiet interrupt" \
    --interrupt --quiet >"$SANDBOX/q.out" 2>"$SANDBOX/q.err"
assert_rc 0 "$?" "--interrupt --quiet should succeed"
[ ! -s "$SANDBOX/q.out" ] || fail "--quiet must suppress the receipt"
assert_eq "$(stop_calls)" "1" "--quiet must not change whether the agent is stopped"

exit 0
