#!/bin/sh
# tests/t-01-enqueue-fifo.sh: 5 adds in a tight loop against one idle agent
# (same-second collisions -- each `add` execs a fresh process, so epoch10 is
# identical across all 5 but pid7 differs). Verifies the FIFO filename
# scheme survives this without corrupting order: after a single foreground
# drain, send.log's cksum sequence must equal the original enqueue order,
# every message must land in sent/, and pending/ must end up empty.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000001-0000-0000-0000-000000000001"
AGENT_NAME="t01-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

t01_i=1
while [ "$t01_i" -le 5 ]; do
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "fifo-msg-$t01_i"
    assert_rc 0 "$?" "add #$t01_i should enqueue and return immediately"
    t01_i=$((t01_i + 1))
done

t01_pending=0
for t01_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t01_f" ] || continue
    t01_pending=$((t01_pending + 1))
done
assert_eq "$t01_pending" "5" "expected 5 pending messages after 5 tight-loop adds"

"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "_dispatch should exit cleanly once all 5 messages drain"

assert_eq "$(mock_send_count)" "5" "send.log should record exactly 5 deliveries"

t01_sent=0
for t01_f in "$dp_dir/sent"/*.msg; do
    [ -e "$t01_f" ] || continue
    t01_sent=$((t01_sent + 1))
done
assert_eq "$t01_sent" "5" "all 5 messages should be in sent/"

t01_pending_after=0
for t01_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t01_f" ] || continue
    t01_pending_after=$((t01_pending_after + 1))
done
assert_eq "$t01_pending_after" "0" "pending/ should be empty after drain"

# FIFO check: send.log's recorded cksum order (seq 1..5) must equal the
# original enqueue order (fifo-msg-1 .. fifo-msg-5), proving same-second
# collisions never scrambled delivery order.
t01_i=1
while [ "$t01_i" -le 5 ]; do
    t01_expected_cksum="$(printf 'fifo-msg-%s\n' "$t01_i" | cksum | cut -d' ' -f1)"
    t01_logged_cksum="$(sed -n "${t01_i}p" "$MOCK_DIR/send.log" | cut -f2)"
    assert_eq "$t01_logged_cksum" "$t01_expected_cksum" \
        "send.log entry $t01_i cksum should match enqueue-order message $t01_i"
    t01_i=$((t01_i + 1))
done

exit 0
