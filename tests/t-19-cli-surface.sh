#!/bin/sh
# tests/t-19-cli-surface.sh: covers the three subcommands that had ZERO test
# invocations -- ls, log, and help -- plus the main dispatch's unknown-
# subcommand path. Found by a coverage audit while triaging gh#1: across the
# whole suite, `add` was invoked 31 times and `_dispatch` 11, while ls, log
# and help were never invoked once. log carries its own hand-rolled option
# loop (-n value validation and an unknown-option guard) that nothing
# exercised, which is the same shape of blind spot gh#1 turned out to be.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

# --- ls with no known agents --------------------------------------------
# $PASEO_QUEUE_HOME exists (setup created it) but holds no agent
# directories, so the glob matches nothing and every iteration is skipped.
t19_out="$("$PQT_BIN" ls 2>"$SANDBOX/ls0.err")"
assert_rc 0 "$?" "ls should exit 0 with no known agents"
[ -z "$t19_out" ] || fail "ls should print nothing when no agents are known (got: $t19_out)"
[ ! -s "$SANDBOX/ls0.err" ] || fail "ls should not warn when no agents are known"

# --- ls with two agents, one of them holding pending messages -----------
AGENT_A="a0000019-0000-0000-0000-00000000000a"
AGENT_B="a0000019-0000-0000-0000-00000000000b"
seed_agent "$AGENT_A" "t19-a-agent" idle 0 0
seed_agent "$AGENT_B" "t19-b-agent" idle 0 0

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_A" "ls-probe-1" --quiet
assert_rc 0 "$?" "add for agent A should succeed"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_A" "ls-probe-2" --quiet
assert_rc 0 "$?" "second add for agent A should succeed"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_B" "ls-probe-3" --quiet
assert_rc 0 "$?" "add for agent B should succeed"

"$PQT_BIN" ls >"$SANDBOX/ls.out" 2>&1
assert_rc 0 "$?" "ls should exit 0 with known agents"

assert_grep "$SANDBOX/ls.out" "$AGENT_A" "ls should list agent A's uuid"
assert_grep "$SANDBOX/ls.out" "$AGENT_B" "ls should list agent B's uuid"
assert_grep "$SANDBOX/ls.out" "t19-a-agent: pending=2 sent=0 failed=0" \
    "ls should report agent A's name and counts"
assert_grep "$SANDBOX/ls.out" "t19-b-agent: pending=1 sent=0 failed=0" \
    "ls should report agent B's name and counts"

# Pending filenames are listed, indented, under their agent.
t19_listed="$(grep -c '^  pending/' "$SANDBOX/ls.out" | head -1 | tr -d ' ')"
[ -n "$t19_listed" ] || t19_listed=0
assert_eq "$t19_listed" "3" "ls should list every pending message filename"

# --- log before any dispatcher has written a log ------------------------
# add only writes dispatch.log via log_line, so a log DOES exist by now for
# both agents. Use a third, hand-planted agent directory with no log file at
# all to reach the no-log branch.
AGENT_C="a0000019-0000-0000-0000-00000000000c"
seed_agent "$AGENT_C" "t19-c-agent" idle 0 0
mkdir -p "$PASEO_QUEUE_HOME/$AGENT_C/pending"

"$PQT_BIN" log "$AGENT_C" >/dev/null 2>"$SANDBOX/log-none.err"
assert_rc 1 "$?" "log should exit 1 when the agent has no dispatch log"
assert_grep "$SANDBOX/log-none.err" "no log for" \
    "log should say the agent has no log"

# --- log default and -n N ------------------------------------------------
dpA_dir="$PASEO_QUEUE_HOME/$AGENT_A"
[ -f "$dpA_dir/dispatch.log" ] || fail "expected add to have written a dispatch log for agent A"

"$PQT_BIN" log "$AGENT_A" >"$SANDBOX/log.out" 2>&1
assert_rc 0 "$?" "log should exit 0 for an agent with a log"
assert_grep "$SANDBOX/log.out" "ENQ" "log should show the ENQ lines add wrote"

# Agent A has exactly two ENQ lines; -n 1 must show only the last.
"$PQT_BIN" log "$AGENT_A" -n 1 >"$SANDBOX/log1.out" 2>&1
assert_rc 0 "$?" "log -n 1 should exit 0"
t19_lines="$(wc -l < "$SANDBOX/log1.out" | tr -d ' ')"
assert_eq "$t19_lines" "1" "log -n 1 should print exactly one line"

# -n 0 is a nonnegative integer and must be accepted, not rejected.
"$PQT_BIN" log "$AGENT_A" -n 0 >"$SANDBOX/log0.out" 2>&1
assert_rc 0 "$?" "log -n 0 should be accepted (0 is a nonnegative integer)"
t19_lines0="$(wc -l < "$SANDBOX/log0.out" | tr -d ' ')"
assert_eq "$t19_lines0" "0" "log -n 0 should print no lines"

# --- log option-loop rejections -----------------------------------------
"$PQT_BIN" log "$AGENT_A" -n >/dev/null 2>"$SANDBOX/log-nov.err"
assert_rc 1 "$?" "log -n without a value should exit 1"
assert_grep "$SANDBOX/log-nov.err" "requires a value" \
    "log -n with no value should say a value is required"

"$PQT_BIN" log "$AGENT_A" -n abc >/dev/null 2>"$SANDBOX/log-bad.err"
assert_rc 1 "$?" "log -n abc should exit 1"
assert_grep "$SANDBOX/log-bad.err" "nonnegative integer" \
    "log -n with a non-integer should say a nonnegative integer is required"

"$PQT_BIN" log "$AGENT_A" -n -5 >/dev/null 2>&1
assert_rc 1 "$?" "log -n -5 should exit 1 (negative is not a nonnegative integer)"

"$PQT_BIN" log "$AGENT_A" --bogus >/dev/null 2>"$SANDBOX/log-opt.err"
assert_rc 1 "$?" "log with an unknown option should exit 1"
assert_grep "$SANDBOX/log-opt.err" "log: unknown option: --bogus" \
    "log should name the unknown option"

# log resolves orphans (resolve_agent ... 1), unlike drain: an agent absent
# from `paseo ls` but with a state directory must still be readable.
ORPHAN_UUID="19191919-0000-0000-0000-000000000019"
mkdir -p "$PASEO_QUEUE_HOME/$ORPHAN_UUID"
printf '%s orphan-with-log\n' "$(printf '%.7s' "$ORPHAN_UUID")" \
    > "$PASEO_QUEUE_HOME/$ORPHAN_UUID/agent.name"
printf 'a line from a dispatcher whose agent is now gone\n' \
    > "$PASEO_QUEUE_HOME/$ORPHAN_UUID/dispatch.log"

"$PQT_BIN" log "$ORPHAN_UUID" >"$SANDBOX/log-orphan.out" 2>&1
assert_rc 0 "$?" "log should read an orphaned agent's log"
assert_grep "$SANDBOX/log-orphan.out" "agent is now gone" \
    "log should print the orphaned agent's log content"

# --- help ----------------------------------------------------------------
for t19_h in help --help -h; do
    "$PQT_BIN" "$t19_h" >"$SANDBOX/help.out" 2>"$SANDBOX/help.err"
    assert_rc 0 "$?" "$t19_h should exit 0"
    assert_grep "$SANDBOX/help.out" "^Usage: paseo-queue" \
        "$t19_h should print usage on stdout"
    [ ! -s "$SANDBOX/help.err" ] || fail "$t19_h should print nothing on stderr"
done

# Help text must document every subcommand the dispatcher accepts, so the
# two cannot drift apart silently.
for t19_sub in add ls rm status drain stop log; do
    assert_grep "$SANDBOX/help.out" "^  $t19_sub" \
        "help should document the $t19_sub subcommand"
done

# --- unknown subcommand, and no subcommand at all -----------------------
"$PQT_BIN" definitely-not-a-subcommand >"$SANDBOX/bad.out" 2>"$SANDBOX/bad.err"
assert_rc 1 "$?" "an unknown subcommand should exit 1"
[ ! -s "$SANDBOX/bad.out" ] || fail "an unknown subcommand must not print usage on stdout"
assert_grep "$SANDBOX/bad.err" "^Usage: paseo-queue" \
    "an unknown subcommand should print usage on stderr"

"$PQT_BIN" >"$SANDBOX/none.out" 2>"$SANDBOX/none.err"
assert_rc 1 "$?" "no subcommand at all should exit 1"
[ ! -s "$SANDBOX/none.out" ] || fail "a bare invocation must not print usage on stdout"
assert_grep "$SANDBOX/none.err" "^Usage: paseo-queue" \
    "a bare invocation should print usage on stderr"

exit 0
