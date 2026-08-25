#!/bin/sh
# tests/t-11-message-hygiene.sh: exercises `add`'s content-hygiene rules --
# empty/whitespace-only stdin rejected, oversize rejected naming the
# offending env var, the arg-text form gaining exactly one trailing
# newline, and the --file form staying byte-identical end to end
# (including through delivery into sent.d/).
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000011-0000-0000-0000-000000000011"
AGENT_NAME="t11-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# --- empty stdin ---
printf '' | PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" >/dev/null 2>&1
assert_rc 1 "$?" "empty stdin message should be rejected"

# --- whitespace-only stdin ---
printf '   \n\t  \n' | PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" >/dev/null 2>&1
assert_rc 1 "$?" "whitespace-only message should be rejected"

t11_pending=0
for t11_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t11_f" ] || continue
    t11_pending=$((t11_pending + 1))
done
assert_eq "$t11_pending" "0" "rejected messages must never reach pending/"

# --- oversize, naming the env var ---
t11_big="$(printf '%200s' '' | tr ' ' 'A')"
t11_out="$(PASEO_QUEUE_MAX_BYTES=100 PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "$t11_big" 2>&1)"
t11_rc=$?
assert_rc 1 "$t11_rc" "oversize message should be rejected"
printf '%s\n' "$t11_out" | grep -q "PASEO_QUEUE_MAX_BYTES" || fail "oversize rejection should name PASEO_QUEUE_MAX_BYTES"

t11_pending=0
for t11_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t11_f" ] || continue
    t11_pending=$((t11_pending + 1))
done
assert_eq "$t11_pending" "0" "oversize message must never reach pending/"

# --- arg-text form gains exactly one trailing newline ---
t11_text="no-newline-in-source"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "$t11_text"
assert_rc 0 "$?" "arg-text add should succeed"

t11_argmsg=""
t11_pending=0
for t11_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t11_f" ] || continue
    t11_pending=$((t11_pending + 1))
    t11_argmsg="$t11_f"
done
assert_eq "$t11_pending" "1" "expected exactly one pending message after the arg-text add"

printf '%s\n' "$t11_text" > "$SANDBOX/expected_argmsg"
cmp -s "$t11_argmsg" "$SANDBOX/expected_argmsg" || fail "arg-text message should be exactly the text plus one trailing newline"

t11_expected_bytes=$(( ${#t11_text} + 1 ))
t11_actual_bytes="$(wc -c < "$t11_argmsg" | tr -d ' ')"
assert_eq "$t11_actual_bytes" "$t11_expected_bytes" "arg-text message should gain exactly one trailing newline (no more, no less)"

# --- --file form stays byte-identical, including in sent.d/ ---
t11_filepath="$SANDBOX/file-msg.txt"
printf 'line-one\nline-two-no-trailing-newline' > "$t11_filepath"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" --file "$t11_filepath"
assert_rc 0 "$?" "--file add should succeed"

t11_pending=0
t11_filemsg=""
for t11_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t11_f" ] || continue
    t11_pending=$((t11_pending + 1))
    [ "$t11_f" = "$t11_argmsg" ] || t11_filemsg="$t11_f"
done
assert_eq "$t11_pending" "2" "expected two pending messages now (arg-text + file)"
[ -n "$t11_filemsg" ] || fail "expected to identify the --file message's staged file"

cmp -s "$t11_filepath" "$t11_filemsg" || fail "--file message must be staged byte-identical (no newline appended)"

"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "dispatcher should exit cleanly after delivering both messages"

t11_pending_after=0
for t11_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t11_f" ] || continue
    t11_pending_after=$((t11_pending_after + 1))
done
assert_eq "$t11_pending_after" "0" "both messages should have been delivered"

t11_found_identical=0
for t11_f in "$MOCK_DIR/sent.d"/*; do
    [ -e "$t11_f" ] || continue
    if cmp -s "$t11_filepath" "$t11_f"; then
        t11_found_identical=1
    fi
done
[ "$t11_found_identical" -eq 1 ] || fail "--file message should appear byte-identical in some sent.d/ entry"

exit 0
