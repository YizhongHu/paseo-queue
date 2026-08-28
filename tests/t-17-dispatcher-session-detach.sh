#!/bin/sh
# tests/t-17-dispatcher-session-detach.sh: the auto-spawned dispatcher must
# run in its OWN session, so tearing down the caller's process group cannot
# take it with it.
#
# Regression test for dispatchers dying seconds after START with
# `EXIT reason=signal sig=TERM`, observed in the real queue when the
# short-lived sandboxed agent shell that called `add` had its process group
# torn down. `add` had already returned 0 with no output, so the message sat
# in pending/ with nothing to report it, and callers read the silence as the
# daemon being unreachable.
#
# The caller here is launched in a session of its own so this test can
# signal that process group without touching its own.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000017-0000-0000-0000-000000000017"
AGENT_NAME="t17-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" running 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# Hold the agent busy briefly so the dispatcher stays alive in its
# busy/waiting branch while we signal the caller's group, then releases and
# delivers. Same idiom as t-03.
mock_set_wait_script "after=5 result=idle set_status=idle"

# wait_for <cond> <timeout> -- same-shell polling loop (t-05's idiom).
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

# Run `add` with the spawn ENABLED (no PASEO_QUEUE_NO_SPAWN here -- the
# spawn is exactly what is under test) inside a fresh session, and print the
# caller's pid, which is that new session's process-group id.
t17_py='
import subprocess, sys

p = subprocess.Popen(
    sys.argv[1:],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
print(p.pid)
p.wait()
'
t17_caller_pgid="$(python3 -c "$t17_py" "$PQT_BIN" add "$AGENT_UUID" "session-detach-probe")"
[ -n "$t17_caller_pgid" ] || fail "could not determine the caller's process-group id"

wait_for '[ -s "'"$dp_dir"'/lock/pid" ]' 15 \
    || fail "no dispatcher was spawned (lock/pid never appeared)"
t17_dpid="$(cat "$dp_dir/lock/pid" 2>/dev/null | tr -d ' ')"
[ -n "$t17_dpid" ] || fail "dispatcher lock/pid is empty"

kill -0 "$t17_dpid" 2>/dev/null || fail "dispatcher $t17_dpid is not alive before the group teardown"

# The dispatcher must lead its own process group: pgid == its own pid, and
# in particular NOT the caller's pgid, which is the group about to be torn
# down. (Session ids are not compared: macOS `ps -o sess=` reports 0 rather
# than a session id, so the check would be vacuous there.)
t17_dpgid="$(ps -o pgid= -p "$t17_dpid" 2>/dev/null | tr -d ' ')"
t17_self_pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"

assert_eq "$t17_dpgid" "$t17_dpid" "dispatcher should lead its own process group"
[ "$t17_dpgid" != "$t17_caller_pgid" ] \
    || fail "dispatcher shares the caller's process group ($t17_dpgid): a group teardown would kill it"
[ "$t17_dpgid" != "$t17_self_pgid" ] \
    || fail "dispatcher shares this test's process group ($t17_dpgid); it was not detached"

# Tear down the caller's process group, exactly as an exiting agent sandbox
# would. The group may already be empty now that `add` has returned, in
# which case kill reports no such process -- that is fine, the assertion
# that matters is the dispatcher surviving.
kill -TERM "-$t17_caller_pgid" 2>/dev/null || :

kill -0 "$t17_dpid" 2>/dev/null \
    || fail "dispatcher died with the caller's process group (the sig=TERM regression)"

# Surviving is not enough: it must still do its job afterwards.
wait_for 'grep -q SEND-OK "'"$dp_dir"'/dispatch.log" 2>/dev/null' 25 \
    || fail "dispatcher survived the group teardown but never delivered the message"

assert_grep "$dp_dir/dispatch.log" "SEND-OK" "delivery should be logged after the group teardown"

t17_pending=0
for t17_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t17_f" ] || continue
    t17_pending=$((t17_pending + 1))
done
assert_eq "$t17_pending" "0" "the message should have left pending/ after delivery"

# grep -c prints 0 and exits 1 when nothing matches, so normalize rather
# than adding a `|| printf 0` fallback (which would emit two lines).
t17_sig_exit="$(grep -c 'reason=signal' "$dp_dir/dispatch.log" 2>/dev/null | head -1 | tr -d ' ')"
[ -n "$t17_sig_exit" ] || t17_sig_exit=0
assert_eq "$t17_sig_exit" "0" "the dispatcher should never log a signal-caused exit in this scenario"

exit 0
