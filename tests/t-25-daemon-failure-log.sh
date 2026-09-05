#!/bin/sh
# tests/t-25-daemon-failure-log.sh: daemon failures must leave evidence, and
# a transient one must not lose the caller's command.
#
# The daemon fails intermittently and the failures were not reproducible on
# demand -- partly the tool's own fault. `paseo ls --json` ran with stderr
# routed to DEVNULL, so the daemon's own error text was discarded every time
# it failed, and a malformed response was silently treated as an empty fleet,
# surfacing as "no agent matches" rather than as a daemon fault. An
# unreproducible fault needs an evidence trail.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

PASEO_QUEUE_LS_RETRY_DELAY=0.1
export PASEO_QUEUE_LS_RETRY_DELAY

AGENT_UUID="a0000025-0000-0000-0000-000000000025"
seed_agent "$AGENT_UUID" "t25-agent" idle 0 0
t25_log="$PASEO_QUEUE_HOME/daemon.log"

# --- persistent failure: exit 3, and the real error is recorded ----------
: > "$MOCK_DIR/down"
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "probe" --quiet >/dev/null 2>&1
assert_rc 3 "$?" "a persistent daemon failure should exit 3"
rm -f "$MOCK_DIR/down"

[ -f "$t25_log" ] || fail "a daemon failure must be recorded in daemon.log"
assert_grep "$t25_log" "LS-FAIL" "the failure should be logged"
assert_grep "$t25_log" "attempt=1" "the first attempt should be logged"
assert_grep "$t25_log" "attempt=2" "the retry should also be logged"
assert_grep "$t25_log" "load=" "the load average should be captured, since load is the suspected trigger"
# The daemon's OWN error text is the point of the exercise.
assert_grep "$t25_log" "stderr=paseo:" "the daemon's stderr must be captured, not discarded"

# --- transient failure: the retry saves the command ---------------------
rm -f "$t25_log"
mkdir -p "$SANDBOX/flaky"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "${1:-}" = "ls" ] && [ ! -f "'"$SANDBOX"'/tripped" ]; then'
    printf '%s\n' '    : > "'"$SANDBOX"'/tripped"'
    printf '%s\n' '    echo "connect: connection refused" >&2'
    printf '%s\n' '    exit 1'
    printf '%s\n' 'fi'
    printf 'exec %s "$@"\n' "$SANDBOX/bin/paseo"
} > "$SANDBOX/flaky/paseo"
chmod +x "$SANDBOX/flaky/paseo"

PATH="$SANDBOX/flaky:$PATH" PASEO_QUEUE_NO_SPAWN=1 \
    "$PQT_BIN" add "$AGENT_UUID" "transient probe" --quiet >/dev/null 2>&1
assert_rc 0 "$?" "a transient daemon failure must NOT lose the command: the retry should recover"

t25_pending=0
for t25_f in "$PASEO_QUEUE_HOME/$AGENT_UUID/pending"/*.msg; do
    [ -e "$t25_f" ] || continue
    t25_pending=$((t25_pending + 1))
done
assert_eq "$t25_pending" "1" "the recovered command should have enqueued its message"

assert_grep "$t25_log" "LS-RECOVERED" "a recovered transient failure should be recorded as such"
assert_grep "$t25_log" "prev_err=connect: connection refused" \
    "the recovery record should name the error it recovered from"

# --- malformed response is a DAEMON fault, not an empty fleet -----------
# A truncated or corrupt response used to parse as [] and surface as
# "no agent matches", so a daemon problem did not even look like one.
rm -f "$t25_log"
mkdir -p "$SANDBOX/trunc"
{
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'if [ "${1:-}" = "ls" ]; then printf "%s" "[{\"id\":\"aaaa"; exit 0; fi'
    printf 'exec %s "$@"\n' "$SANDBOX/bin/paseo"
} > "$SANDBOX/trunc/paseo"
chmod +x "$SANDBOX/trunc/paseo"

PATH="$SANDBOX/trunc:$PATH" PASEO_QUEUE_NO_SPAWN=1 \
    "$PQT_BIN" add "$AGENT_UUID" "probe" --quiet >/dev/null 2>&1
assert_rc 3 "$?" "a malformed daemon response must exit 3 (daemon), not 2 (no agent matches)"
assert_grep "$t25_log" "parse_error=" "the parse failure should be recorded with its reason"

# --- diagnostics must never be able to fail a command -------------------
# An unwritable log directory is not a reason to fail an enqueue.
chmod 500 "$PASEO_QUEUE_HOME" 2>/dev/null || :
PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "still works" --quiet >/dev/null 2>&1
t25_rc=$?
chmod 700 "$PASEO_QUEUE_HOME" 2>/dev/null || :
assert_rc 0 "$t25_rc" "a failure to write diagnostics must not fail the command"

exit 0
