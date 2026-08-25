#!/bin/sh
# tests/t-10-resolve-names.sh: two agents deliberately share a 4-char id
# prefix ("abcd") but diverge by the 5th character, so their 7-char shortIds
# differ. Verifies resolve_agent()'s matching rules: the shared 4-char
# prefix is ambiguous (exit 2, both candidates listed); an exact agent name,
# a full UUID, and either agent's unique 7-char shortId each resolve to
# exactly the intended agent (proven by which agent's pending/ gains a
# file).
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

UUID1="abcd1111-1111-1111-1111-111111111111"
UUID2="abcd2222-2222-2222-2222-222222222222"
NAME1="t10-agent-one"
NAME2="t10-agent-two"

seed_agent "$UUID1" "$NAME1" idle 0 0
seed_agent "$UUID2" "$NAME2" idle 0 0

dp1_dir="$PASEO_QUEUE_HOME/$UUID1"
dp2_dir="$PASEO_QUEUE_HOME/$UUID2"

t10_count_pending() {
    tcp_dir="$1"
    tcp_n=0
    for tcp_f in "$tcp_dir/pending"/*.msg; do
        [ -e "$tcp_f" ] || continue
        tcp_n=$((tcp_n + 1))
    done
    printf '%s\n' "$tcp_n"
}

# Ambiguous 4-char prefix (shared by both agents) must be rejected.
t10_out="$(PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "abcd" "ambiguous-attempt" 2>&1)"
t10_rc=$?
assert_rc 2 "$t10_rc" "shared 4-char prefix should be ambiguous"
printf '%s\n' "$t10_out" | grep -q "$UUID1" || fail "ambiguous listing should mention $UUID1"
printf '%s\n' "$t10_out" | grep -q "$UUID2" || fail "ambiguous listing should mention $UUID2"
assert_eq "$(t10_count_pending "$dp1_dir")" "0" "ambiguous add must not enqueue anything for agent 1"
assert_eq "$(t10_count_pending "$dp2_dir")" "0" "ambiguous add must not enqueue anything for agent 2"

# Exact name resolves unambiguously (never a name prefix).
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$NAME1" "exact-name-test"
assert_rc 0 "$?" "exact agent name should resolve"
assert_eq "$(t10_count_pending "$dp1_dir")" "1" "exact-name add should have targeted agent 1"
assert_eq "$(t10_count_pending "$dp2_dir")" "0" "exact-name add must not have touched agent 2"

# Full UUID resolves.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$UUID2" "full-uuid-test"
assert_rc 0 "$?" "full UUID should resolve"
assert_eq "$(t10_count_pending "$dp2_dir")" "1" "full-UUID add should have targeted agent 2"

# Each agent's unique 7-char shortId resolves (differs at char 5, so
# neither is itself ambiguous even though both share the first 4 chars).
t10_short1="$(printf '%.7s' "$UUID1")"
t10_short2="$(printf '%.7s' "$UUID2")"
[ "$t10_short1" != "$t10_short2" ] || fail "test setup bug: shortIds must differ"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$t10_short1" "shortid-test-1"
assert_rc 0 "$?" "agent 1's unique 7-char shortId should resolve"
assert_eq "$(t10_count_pending "$dp1_dir")" "2" "shortId add should have targeted agent 1 again"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$t10_short2" "shortid-test-2"
assert_rc 0 "$?" "agent 2's unique 7-char shortId should resolve"
assert_eq "$(t10_count_pending "$dp2_dir")" "2" "shortId add should have targeted agent 2 again"

exit 0
