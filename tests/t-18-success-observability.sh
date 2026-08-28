#!/bin/sh
# tests/t-18-success-observability.sh: success must be observable. Before
# this, a successful `add` emitted zero bytes on BOTH streams, so the only
# positive signal a caller had was the absence of output -- which is how a
# ~21h delivery outage went unnoticed, and why a sandboxed agent could not
# tell "sent" from "silently did nothing". `rm` was silent too, including on
# the destructive --all path.
#
# Asserted here: add prints a receipt naming the real pending/ file, --wait
# additionally reports delivery (since a bare exit 0 only means enqueued),
# --quiet suppresses both, rm names every file it removes, and failures
# still say nothing on stdout.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000018-0000-0000-0000-000000000018"
AGENT_NAME="t18-agent"
AGENT_SHORT="a000001"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

# --- add prints a receipt on stdout, nothing on stderr ---
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "observability-probe" \
    >"$SANDBOX/add.out" 2>"$SANDBOX/add.err"
assert_rc 0 "$?" "add should succeed"

[ -s "$SANDBOX/add.out" ] || fail "successful add must print a receipt on stdout, not stay silent"
[ ! -s "$SANDBOX/add.err" ] || fail "successful add must keep stderr empty (got: $(cat "$SANDBOX/add.err"))"
assert_grep "$SANDBOX/add.out" "^paseo-queue: enqueued $AGENT_SHORT pending/" \
    "receipt should name the agent short id and the pending/ path"

t18_lines="$(wc -l < "$SANDBOX/add.out" | tr -d ' ')"
assert_eq "$t18_lines" "1" "a plain add should print exactly one receipt line"

# The receipt must name the file that actually exists -- a receipt naming a
# path the caller cannot then inspect would be worse than silence.
t18_named="$(sed -n 's|^paseo-queue: enqueued [^ ]* pending/\(.*\)$|\1|p' "$SANDBOX/add.out")"
[ -n "$t18_named" ] || fail "could not parse the message name out of the receipt"
[ -e "$dp_dir/pending/$t18_named" ] \
    || fail "receipt names pending/$t18_named but no such file exists"

# --- --quiet suppresses the receipt on both streams ---
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "quiet-probe" --quiet \
    >"$SANDBOX/quiet.out" 2>"$SANDBOX/quiet.err"
assert_rc 0 "$?" "add --quiet should succeed"
[ ! -s "$SANDBOX/quiet.out" ] || fail "--quiet must print nothing on stdout (got: $(cat "$SANDBOX/quiet.out"))"
[ ! -s "$SANDBOX/quiet.err" ] || fail "--quiet must print nothing on stderr (got: $(cat "$SANDBOX/quiet.err"))"

# --- failures stay off stdout ---
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" --waitt \
    >"$SANDBOX/bad.out" 2>"$SANDBOX/bad.err"
assert_rc 1 "$?" "an unknown option should still fail"
[ ! -s "$SANDBOX/bad.out" ] || fail "a failing add must not print to stdout (got: $(cat "$SANDBOX/bad.out"))"
[ -s "$SANDBOX/bad.err" ] || fail "a failing add must still explain itself on stderr"

# --- --wait reports delivery, not just enqueue ---
# Two pending messages exist from the adds above; deliver them so the queue
# is clean, then use --wait on a fresh one with the dispatcher driven
# manually (NO_SPAWN keeps the auto-spawn out of the way, and _dispatch runs
# in the foreground, so by the time --wait polls, delivery has happened).
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
assert_rc 0 "$?" "dispatcher should drain the earlier probes"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "wait-probe" >/dev/null 2>&1
assert_rc 0 "$?" "add for the --wait probe should succeed"
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
assert_rc 0 "$?" "dispatcher should deliver the --wait probe"

# The message is already in sent/, so --wait resolves on its first poll.
t18_waitmsg="$(ls -1 "$dp_dir/sent" 2>/dev/null | tail -1)"
[ -n "$t18_waitmsg" ] || fail "expected a delivered message in sent/"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "wait-report-probe" --wait --wait-timeout 5 \
    >"$SANDBOX/wait.out" 2>"$SANDBOX/wait.err" &
t18_waitpid=$!
"$PQT_BIN" _dispatch "$AGENT_UUID" >/dev/null 2>&1
wait "$t18_waitpid"
assert_rc 0 "$?" "add --wait should exit 0 once the message is delivered"

assert_grep "$SANDBOX/wait.out" "^paseo-queue: enqueued $AGENT_SHORT pending/" \
    "--wait should still print the enqueue receipt"
assert_grep "$SANDBOX/wait.out" "^paseo-queue: delivered $AGENT_SHORT " \
    "--wait should report delivery, since a bare exit 0 only means enqueued"

# --- rm names what it deleted ---
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "rm-single-probe" --quiet
assert_rc 0 "$?" "add for the rm probe should succeed"
t18_rmtarget="$(ls -1 "$dp_dir/pending" | head -1)"
[ -n "$t18_rmtarget" ] || fail "expected a pending message to remove"

"$PQT_BIN" rm "$AGENT_UUID" "$t18_rmtarget" >"$SANDBOX/rm1.out" 2>"$SANDBOX/rm1.err"
assert_rc 0 "$?" "rm of a single message should succeed"
assert_grep "$SANDBOX/rm1.out" "^paseo-queue: removed $AGENT_SHORT pending/$t18_rmtarget$" \
    "rm should name the file it deleted"

# --- rm --all names every casualty plus a count ---
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "rm-all-probe-1" --quiet
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "rm-all-probe-2" --quiet

"$PQT_BIN" rm "$AGENT_UUID" --all >"$SANDBOX/rmall.out" 2>"$SANDBOX/rmall.err"
assert_rc 0 "$?" "rm --all should succeed"

t18_named_count="$(grep -c "^paseo-queue: removed $AGENT_SHORT pending/" "$SANDBOX/rmall.out" | head -1 | tr -d ' ')"
[ -n "$t18_named_count" ] || t18_named_count=0
assert_eq "$t18_named_count" "2" "rm --all should name each removed file"
assert_grep "$SANDBOX/rmall.out" "^paseo-queue: removed 2 pending message(s) for $AGENT_SHORT$" \
    "rm --all should report how many it removed"

t18_pending=0
for t18_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t18_f" ] || continue
    t18_pending=$((t18_pending + 1))
done
assert_eq "$t18_pending" "0" "rm --all should leave pending/ empty"

exit 0
