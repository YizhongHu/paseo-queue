#!/bin/sh
# tests/t-16-input-path-equivalence.sh: stages one hostile payload through
# inline, --file, and stdin input paths, then compares staged and delivered
# bytes. The inline form is expected to gain exactly one trailing newline.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000016-0000-0000-0000-000000000016"
AGENT_NAME="t16-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"
t16_source="$SANDBOX/hostile-payload"
t16_inline_expected="$SANDBOX/hostile-payload-inline"
t16_payload=""

# Keep every metacharacter literal: printf arguments are single-quoted, and
# the final format has no newline so the inline rule is observable.
printf '%s\n%s\n%s\n%s\n%s\n%s' \
    '- first markdown bullet with an embedded '\''single quote' \
    '- second markdown bullet with an embedded "double quote"' \
    '' \
    'quoted values: '\''single quote'\'' and "double quote"' \
    'literal $VAR survives, with a backslash: \\' \
    '--flag-shaped token must remain message text' > "$t16_source"
cat "$t16_source" > "$t16_inline_expected"
printf '\n' >> "$t16_inline_expected"
t16_payload="$(cat "$t16_source")"

# --file and stdin must stage the source bytes exactly.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" --file "$t16_source"
assert_rc 0 "$?" "--file hostile payload add should succeed"

cat "$t16_source" | PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID"
assert_rc 0 "$?" "stdin hostile payload add should succeed"

t16_pending=0
for t16_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t16_f" ] || continue
    t16_pending=$((t16_pending + 1))
    cmp -s "$t16_source" "$t16_f" || fail "--file/stdin staged payload must be byte-identical to source"
done
assert_eq "$t16_pending" "2" "expected file and stdin payloads in pending"

# Deliver the known-good paths before checking inline, so the unfixed parser
# still proves that --file and stdin pass independently.
"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "dispatcher should deliver --file and stdin payloads"

t16_delivered_raw=0
for t16_f in "$MOCK_DIR/sent.d"/*; do
    [ -e "$t16_f" ] || continue
    if cmp -s "$t16_source" "$t16_f"; then
        t16_delivered_raw=$((t16_delivered_raw + 1))
    fi
done
assert_eq "$t16_delivered_raw" "2" "--file and stdin payloads should survive delivery"

# This is the issue #1 assertion on the unfixed binary: a leading markdown
# bullet is message text, not an option, on the inline positional path.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "$t16_payload" 2>/dev/null
t16_inline_rc=$?

assert_rc 0 "$t16_inline_rc" "inline hostile payload add should succeed"

# The successful inline case is exactly source plus one trailing newline.
t16_pending=0
for t16_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t16_f" ] || continue
    t16_pending=$((t16_pending + 1))
    cmp -s "$t16_inline_expected" "$t16_f" || fail "inline staged payload must equal source plus one trailing newline"
done
assert_eq "$t16_pending" "1" "expected inline payload in pending"

"$PQT_BIN" _dispatch "$AGENT_UUID"
assert_rc 0 "$?" "dispatcher should deliver inline payload"

t16_delivered_inline=0
for t16_f in "$MOCK_DIR/sent.d"/*; do
    [ -e "$t16_f" ] || continue
    if cmp -s "$t16_inline_expected" "$t16_f"; then
        t16_delivered_inline=$((t16_delivered_inline + 1))
    fi
done
assert_eq "$t16_delivered_inline" "1" "inline payload should survive delivery"

exit 0
