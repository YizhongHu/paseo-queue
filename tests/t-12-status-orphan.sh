#!/bin/sh
# tests/t-12-status-orphan.sh: hand-plants a queue state directory for a
# UUID that never appears in agents.tsv (simulating an agent that was
# archived/removed after messages were queued for it). `status` must mark
# it ORPHANED with a stderr WARN (it also has pending messages and no live
# dispatcher, which independently triggers a WARN), `rm <uuid> --all` must
# empty and then remove the directory via the orphan escape hatch, and
# `status` must exit 3 when the daemon itself is unreachable.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

ORPHAN_UUID="99999999-8888-7777-6666-555555555555"
dp_dir="$PASEO_QUEUE_HOME/$ORPHAN_UUID"

mkdir -p "$dp_dir/pending" "$dp_dir/sent" "$dp_dir/failed" "$dp_dir/tmp"
printf '%s %s\n' "$(printf '%.7s' "$ORPHAN_UUID")" "orphan-agent" > "$dp_dir/agent.name"
printf 'a message queued for an agent that is now gone\n' > "$dp_dir/pending/orphan-msg-0001.msg"

t12_out="$("$PQT_BIN" status 2>"$SANDBOX/status.err")"
t12_rc=$?
assert_rc 0 "$t12_rc" "status should exit 0 while the daemon is reachable"

printf '%s\n' "$t12_out" | grep -q "$ORPHAN_UUID" || fail "status output should mention the orphaned uuid"
printf '%s\n' "$t12_out" | grep -q "ORPHANED" || fail "status output should tag the agent ORPHANED"
grep -q "WARN" "$SANDBOX/status.err" || fail "status should emit a stderr WARN for the orphaned/undispatched agent"

# rm --all via the orphan escape hatch (full 36-char UUID, absent from
# `paseo ls`, but with an existing state directory).
"$PQT_BIN" rm "$ORPHAN_UUID" --all
assert_rc 0 "$?" "rm --all should succeed via the orphan escape hatch"

[ -d "$dp_dir" ] && fail "orphan directory should be fully removed once emptied (no lock, no agent, no files left)"

# --- an orphan holding a STALE lock must also be reclaimable -------------
# Same orphan escape hatch, but with a lock/ left behind by a dispatcher
# that died without releasing it. This used to be a permanent dead end:
# `drain` exits 2 (cannot resolve an orphaned agent), and `rm --all` left
# the directory in place because pq_dir_is_empty() counts any lock/ as
# non-empty, so `status` kept reporting state=running for a dead pid with
# no command able to clear it.
ORPHAN2_UUID="99999999-8888-7777-6666-444444444444"
dp2_dir="$PASEO_QUEUE_HOME/$ORPHAN2_UUID"

mkdir -p "$dp2_dir/pending" "$dp2_dir/sent" "$dp2_dir/failed" "$dp2_dir/tmp" "$dp2_dir/lock"
printf '%s %s\n' "$(printf '%.7s' "$ORPHAN2_UUID")" "orphan-stale-lock-agent" > "$dp2_dir/agent.name"
printf 'a message stranded behind a stale lock\n' > "$dp2_dir/pending/orphan2-msg-0001.msg"
printf 'running\n' > "$dp2_dir/state"

# A pid that is definitely not alive: allocate one from a process that has
# already exited, so the recorded holder cannot possibly be running.
(exit 0) &
t12_dead_pid=$!
wait "$t12_dead_pid" 2>/dev/null
kill -0 "$t12_dead_pid" 2>/dev/null && fail "test setup: pid $t12_dead_pid is unexpectedly still alive"
printf '%s\n' "$t12_dead_pid" > "$dp2_dir/lock/pid"

# drain cannot help here -- it resolves the agent first, and this one is
# gone. Asserted so the test documents WHY rm has to be the reclaim path.
"$PQT_BIN" drain "$ORPHAN2_UUID" >/dev/null 2>&1
assert_rc 2 "$?" "drain should exit 2 for an orphaned agent (it cannot resolve)"

"$PQT_BIN" rm "$ORPHAN2_UUID" --all >"$SANDBOX/rm-stale.out" 2>&1
assert_rc 0 "$?" "rm --all should succeed for an orphan holding a stale lock"
assert_grep "$SANDBOX/rm-stale.out" "orphan2-msg-0001.msg" \
    "rm --all should name the message it removed"

[ -d "$dp2_dir" ] && fail "orphan directory with a STALE lock should also be fully removed"

# --- a LIVE lock must still protect the directory ------------------------
# The reclaim above must not generalize into deleting a queue whose
# dispatcher is alive. Same orphan shape, but lock/pid names this very test
# process, which is definitely running.
ORPHAN3_UUID="99999999-8888-7777-6666-333333333333"
dp3_dir="$PASEO_QUEUE_HOME/$ORPHAN3_UUID"

mkdir -p "$dp3_dir/pending" "$dp3_dir/sent" "$dp3_dir/failed" "$dp3_dir/tmp" "$dp3_dir/lock"
printf '%s %s\n' "$(printf '%.7s' "$ORPHAN3_UUID")" "orphan-live-lock-agent" > "$dp3_dir/agent.name"

# lock_holder_alive() requires BOTH that kill -0 succeeds and that
# `ps -o command=` for the pid mentions paseo-queue, so the holder cannot
# just be this test's own shell -- it has to look like a dispatcher. Hence
# a backgrounded sleep whose argv carries the literal string.
sh -c ': paseo-queue stand-in holder; sleep 30' &
t12_live_pid=$!
printf '%s\n' "$t12_live_pid" > "$dp3_dir/lock/pid"
kill -0 "$t12_live_pid" 2>/dev/null || fail "test setup: stand-in holder $t12_live_pid did not start"
ps -p "$t12_live_pid" -o command= 2>/dev/null | grep -q 'paseo-queue' \
    || fail "test setup: stand-in holder's command does not mention paseo-queue"

"$PQT_BIN" rm "$ORPHAN3_UUID" --all >/dev/null 2>&1
t12_rm3_rc=$?
kill "$t12_live_pid" 2>/dev/null
wait "$t12_live_pid" 2>/dev/null

assert_rc 0 "$t12_rm3_rc" "rm --all should still succeed with a live lock present"
[ -d "$dp3_dir" ] || fail "a queue whose lock holder is ALIVE must not be removed"
[ -d "$dp3_dir/lock" ] || fail "a live lock must not be broken by rm --all"

rm -rf "$dp3_dir"

# status exits 3 when the daemon (ls) itself is unreachable.
: > "$MOCK_DIR/down"
"$PQT_BIN" status >/dev/null 2>"$SANDBOX/status2.err"
t12_rc2=$?
assert_rc 3 "$t12_rc2" "status should exit 3 when paseo ls --json fails"
rm -f "$MOCK_DIR/down"

exit 0
