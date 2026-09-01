#!/bin/sh
# tests/t-24-interrupt-crash-safety.sh: an interrupt that dies mid-delivery
# must leave its message recoverable, never stranded.
#
# The normal enqueue path is recoverable by construction: `add` spawns a
# dispatcher, so if anything dies the dispatcher still delivers. The interrupt
# path deliberately does NOT spawn one up front, because it would race the
# interrupt for the same file. That left a gap: a death between
# INTERRUPT-BEGIN and the move into sent/ stranded the message in pending/
# with nothing coming for it.
#
# Observed in the wild before the fix -- a real queue sat like this for 14
# hours, with no INTERRUPT-OK and no INTERRUPT-FAIL ever logged:
#   ENQ             1788225629-0067910-0000.msg
#   INTERRUPT-BEGIN 1788225629-0067910-0000.msg
#   (nothing)
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000024-0000-0000-0000-000000000024"
seed_agent "$AGENT_UUID" "t24-agent" idle 0 0
dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# A `paseo` that blocks on send, so the interrupt can be killed while inside
# it. Everything else delegates to the real mock. Placed first on PATH.
mkdir -p "$SANDBOX/slowbin"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "${1:-}" = "send" ]; then sleep 30; fi'
    printf 'exec %s "$@"\n' "$SANDBOX/bin/paseo"
} > "$SANDBOX/slowbin/paseo"
chmod +x "$SANDBOX/slowbin/paseo"

wait_for() {
    wf_cond="$1"; wf_timeout="$2"; wf_elapsed=0
    while [ "$wf_elapsed" -lt "$wf_timeout" ]; do
        eval "$wf_cond" && return 0
        sleep 1
        wf_elapsed=$((wf_elapsed + 1))
    done
    return 1
}

# --- kill the interrupt while it is inside the send ---------------------
PATH="$SANDBOX/slowbin:$PATH" "$PQT_BIN" add "$AGENT_UUID" \
    "interrupt that will be killed mid-send" --interrupt >/dev/null 2>&1 &
t24_pid=$!

wait_for 'grep -q INTERRUPT-BEGIN "'"$dp_dir"'/dispatch.log" 2>/dev/null' 20 \
    || fail "the interrupt never reached INTERRUPT-BEGIN"

kill -TERM "$t24_pid" 2>/dev/null
wait "$t24_pid" 2>/dev/null

# --- the message must NOT be stranded ----------------------------------
t24_pending=0
for t24_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t24_f" ] || continue
    t24_pending=$((t24_pending + 1))
done
assert_eq "$t24_pending" "1" "the killed interrupt should leave its message queued, not lost"

assert_grep "$dp_dir/dispatch.log" "INTERRUPT-ABORT" \
    "an aborted interrupt should record that it was aborted"

# THE POINT: a dispatcher must have been spawned to recover it. Without the
# fix nothing is coming and the message sits in pending/ forever.
wait_for 'grep -qE "START|SKIP" "'"$dp_dir"'/dispatch.log"' 20 \
    || fail "no dispatcher was spawned to recover the stranded message"

wait_for '[ "$(ls -1 "'"$dp_dir"'/sent" 2>/dev/null | wc -l | tr -d " ")" -ge 1 ]' 45 \
    || fail "the recovered message was never delivered"

t24_pending_after=0
for t24_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t24_f" ] || continue
    t24_pending_after=$((t24_pending_after + 1))
done
assert_eq "$t24_pending_after" "0" "pending/ should be empty once the message is recovered"

# Exactly once, not twice: the aborted interrupt never filed it as sent, so
# the dispatcher is the only deliverer.
t24_sends=0
for t24_f in "$MOCK_DIR/sent.d"/*; do
    [ -e "$t24_f" ] || continue
    t24_sends=$((t24_sends + 1))
done
assert_eq "$t24_sends" "1" "the recovered message must be delivered exactly once"

exit 0
