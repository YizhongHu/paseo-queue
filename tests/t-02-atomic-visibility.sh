#!/bin/sh
# tests/t-02-atomic-visibility.sh: hand-plants a torn/partial file directly
# in tmp/ (bypassing `add` entirely, simulating a write that was interrupted
# before the atomic tmp/->pending/ mv) and proves the dispatcher never scans
# tmp/ at all: the planted file is never delivered, no matter how many times
# _dispatch runs. Then a real `add` is checked pre-dispatch to confirm
# exactly one pending/ file exists and tmp/ staging never leaks into
# pending/ or sent/.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000002-0000-0000-0000-000000000002"
AGENT_NAME="t02-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"
mkdir -p "$dp_dir/pending" "$dp_dir/sent" "$dp_dir/failed" "$dp_dir/tmp"

t02_planted="$dp_dir/tmp/stage.99999"
printf 'PARTIAL-UNFINISHED-CONTENT-NO-NEWLINE' > "$t02_planted"
t02_planted_cksum="$(cksum < "$t02_planted" | cut -d' ' -f1)"

# Run the dispatcher against an otherwise-empty pending/: it should linger
# briefly (PASEO_QUEUE_LINGER=1 per common.sh's fast knobs) and exit cleanly
# without ever touching tmp/.
"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "_dispatch should exit cleanly with an empty pending/"

[ -e "$t02_planted" ] || fail "planted tmp/ file must remain untouched by the dispatcher"
assert_eq "$(mock_send_count)" "0" "planted tmp/ file must never be delivered"
[ -e "$dp_dir/sent/$(basename "$t02_planted")" ] && fail "planted file must never appear in sent/"

# Now perform a real add and inspect state *before* dispatching again.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "real atomic-visibility message"
assert_rc 0 "$?" "real add should enqueue successfully"

t02_pending=0
t02_realmsg=""
for t02_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t02_f" ] || continue
    t02_pending=$((t02_pending + 1))
    t02_realmsg="$t02_f"
done
assert_eq "$t02_pending" "1" "exactly one pending/ file should exist pre-dispatch after the real add"

t02_tmp_count=0
for t02_f in "$dp_dir/tmp"/*; do
    [ -e "$t02_f" ] || continue
    t02_tmp_count=$((t02_tmp_count + 1))
done
assert_eq "$t02_tmp_count" "1" "tmp/ should hold only the originally planted file (add's own staging file must not linger)"
[ -e "$t02_planted" ] || fail "planted tmp/ file should still be present (untouched by the real add)"

# Drain again: the real message must be delivered, but the planted tmp/
# file must still never surface in sent/ or send.log.
"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "_dispatch should exit cleanly after delivering the real message"

assert_eq "$(mock_send_count)" "1" "exactly one real delivery should have happened, ever"
[ -e "$dp_dir/sent/$(basename "$t02_realmsg")" ] || fail "real message should now be in sent/"
[ -e "$dp_dir/pending/$(basename "$t02_realmsg")" ] && fail "real message should have left pending/"

grep -q "$t02_planted_cksum" "$MOCK_DIR/send.log" 2>/dev/null && \
    fail "planted tmp/ file's checksum must never appear in send.log"
[ -e "$t02_planted" ] || fail "planted tmp/ file must still be present, untouched, after the real drain"

exit 0
