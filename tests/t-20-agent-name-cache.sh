#!/bin/sh
# tests/t-20-agent-name-cache.sh: the cached display name must not go stale
# in a way that makes the tool advertise an identifier it then rejects.
#
# agent.name is a display cache. `ls` reads it and deliberately never contacts
# the daemon, so `ls` keeps working during an outage -- it is the command you
# run WHEN things are broken. The cost is that a renamed agent shows a stale
# name, and a stale name does not resolve, so `ls` could print an identifier
# that `add` rejects with exit 2 (issue #9).
#
# The chosen fix keeps `ls` local and instead refreshes the cache from every
# command that already holds a live name. Asserted here: any successful
# resolve converges that agent's cache, and `status` converges EVERY known
# agent's cache in one run, because it holds live names for all of them.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_A="a0000020-0000-0000-0000-00000000000a"
AGENT_B="a0000020-0000-0000-0000-00000000000b"

seed_agent "$AGENT_A" "a-name-after-rename" idle 0 0
seed_agent "$AGENT_B" "b-name-after-rename" idle 0 0

dpA_dir="$PASEO_QUEUE_HOME/$AGENT_A"
dpB_dir="$PASEO_QUEUE_HOME/$AGENT_B"

# Create both queues, then plant stale cached names as a rename would leave.
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_A" "seed-a" --quiet
assert_rc 0 "$?" "seeding agent A should succeed"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_B" "seed-b" --quiet
assert_rc 0 "$?" "seeding agent B should succeed"

printf '%s a-name-BEFORE-rename\n' "$(printf '%.7s' "$AGENT_A")" > "$dpA_dir/agent.name"
printf '%s b-name-BEFORE-rename\n' "$(printf '%.7s' "$AGENT_B")" > "$dpB_dir/agent.name"

# --- the trap: ls advertises a name that does not resolve ----------------
t20_out="$("$PQT_BIN" ls 2>/dev/null)"
printf '%s\n' "$t20_out" | grep -q "a-name-BEFORE-rename" \
    || fail "setup: ls should be showing the stale cached name at this point"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "a-name-BEFORE-rename" "probe" --quiet >/dev/null 2>&1
assert_rc 2 "$?" "a stale name must not resolve (this is why showing it is a trap)"

# --- a successful resolve converges THAT agent's cache -------------------
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "a-name-after-rename" "probe" --quiet
assert_rc 0 "$?" "resolving by the live name should succeed"

assert_grep "$dpA_dir/agent.name" "a-name-after-rename" \
    "a successful resolve should refresh agent A's cached name"

t20_out="$("$PQT_BIN" ls 2>/dev/null)"
printf '%s\n' "$t20_out" | grep -q "a-name-after-rename" \
    || fail "ls should now show agent A's live name"
printf '%s\n' "$t20_out" | grep -q "a-name-BEFORE-rename" \
    && fail "ls should no longer show agent A's stale name"

# Agent B was never touched, so it must still be stale — this pins that the
# refresh is driven by activity and is not a blanket daemon call from ls.
assert_grep "$dpB_dir/agent.name" "b-name-BEFORE-rename" \
    "agent B should still be stale, since nothing has resolved it yet"

# --- status converges EVERY known agent in one run ----------------------
"$PQT_BIN" status >/dev/null 2>&1
assert_rc 0 "$?" "status should exit 0 while the daemon is reachable"

assert_grep "$dpB_dir/agent.name" "b-name-after-rename" \
    "one status run should refresh every known agent's cached name"

t20_out="$("$PQT_BIN" ls 2>/dev/null)"
printf '%s\n' "$t20_out" | grep -q "b-name-after-rename" \
    || fail "ls should show agent B's live name after status converged it"

# And the previously-rejected identifier is no longer being advertised.
printf '%s\n' "$t20_out" | grep -q "BEFORE-rename" \
    && fail "ls must not advertise any stale name once status has run"

# --- ls must remain usable with the daemon unreachable ------------------
# This is the reason ls was NOT made daemon-dependent: it is what you run
# when the daemon is down, so it must not fail then.
: > "$MOCK_DIR/down"
t20_out="$("$PQT_BIN" ls 2>"$SANDBOX/ls-down.err")"
assert_rc 0 "$?" "ls must still exit 0 when the daemon is unreachable"
printf '%s\n' "$t20_out" | grep -q "$AGENT_A" \
    || fail "ls must still list agents when the daemon is unreachable"
[ ! -s "$SANDBOX/ls-down.err" ] \
    || fail "ls should not warn when the daemon is unreachable (got: $(cat "$SANDBOX/ls-down.err"))"
rm -f "$MOCK_DIR/down"

exit 0
