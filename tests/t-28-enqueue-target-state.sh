#!/bin/sh
# tests/t-28-enqueue-target-state.sh: the enqueue receipt must say what it
# just addressed, and warn when the target cannot currently read it.
#
# `enqueued <file>` is a statement about the SENDER's side only: the message
# is on disk and correctly addressed. It says nothing about whether the
# target will run again to read it. A manager hit this and could not tell a
# message in flight from one parked indefinitely.
#
# What this can and cannot do. Paseo exposes closed/idle/running/error and has
# NO terminal state, so an agent that has FINISHED its work reports `idle`,
# indistinguishable from one merely between turns -- the daemon does not know
# either, so no warning is possible for that case. A `closed` target is
# different: the dispatcher will halt with halted-closed rather than deliver,
# so the sender is told at enqueue time instead of discovering it later.
#
# The pending/ path stays the LAST field so it remains extractable with $NF.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

IDLE_UUID="a0000028-0000-0000-0000-00000000001d"
CLOSED_UUID="a0000028-0000-0000-0000-00000000000c"
seed_agent "$IDLE_UUID" "t28-idle-agent" idle 0 0
seed_agent "$CLOSED_UUID" "t28-closed-agent" closed 0 0

# --- an idle target: state reported, no warning -------------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$IDLE_UUID" "to an idle agent" \
    >"$SANDBOX/idle.out" 2>"$SANDBOX/idle.err"
assert_rc 0 "$?" "enqueue to an idle agent should succeed"
assert_grep "$SANDBOX/idle.out" "^paseo-queue: enqueued a000002 (target: idle) pending/" \
    "the receipt should name the target state"
[ ! -s "$SANDBOX/idle.err" ] \
    || fail "an idle target should not warn (got: $(cat "$SANDBOX/idle.err"))"

# The path must remain the last whitespace-separated field.
t28_last="$(awk '{print $NF}' "$SANDBOX/idle.out")"
case "$t28_last" in
    pending/*.msg) : ;;
    *) fail "the pending/ path must stay the last field, got [$t28_last]" ;;
esac
[ -e "$PASEO_QUEUE_HOME/$IDLE_UUID/${t28_last}" ] \
    || fail "the receipt must name a file that exists: $t28_last"

# --- a closed target: still enqueued, but the sender is told -------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$CLOSED_UUID" "to a closed agent" \
    >"$SANDBOX/closed.out" 2>"$SANDBOX/closed.err"
assert_rc 0 "$?" "enqueue to a closed agent should still succeed: the queue preserves it"
assert_grep "$SANDBOX/closed.out" "(target: closed)" \
    "the receipt should report the closed state"
assert_grep "$SANDBOX/closed.err" "WARN" \
    "a closed target must warn, since the message cannot be read until it revives"
assert_grep "$SANDBOX/closed.err" "halted-closed" \
    "the warning should name the state the dispatcher will land in"

# The message is still queued -- warning, not refusal.
t28_pending=0
for t28_f in "$PASEO_QUEUE_HOME/$CLOSED_UUID/pending"/*.msg; do
    [ -e "$t28_f" ] || continue
    t28_pending=$((t28_pending + 1))
done
assert_eq "$t28_pending" "1" "the message must still be queued for a closed agent"

# --- --quiet suppresses the receipt but NOT the warning -----------------
# The warning is the whole point; silencing it with routine output would
# reintroduce exactly the silence being fixed.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$CLOSED_UUID" "quiet to closed" --quiet \
    >"$SANDBOX/q.out" 2>"$SANDBOX/q.err"
assert_rc 0 "$?" "quiet enqueue to a closed agent should succeed"
[ ! -s "$SANDBOX/q.out" ] || fail "--quiet must suppress the receipt"
assert_grep "$SANDBOX/q.err" "WARN" \
    "--quiet must NOT suppress the closed-target warning"

exit 0
