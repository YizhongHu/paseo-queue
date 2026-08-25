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

# status exits 3 when the daemon (ls) itself is unreachable.
: > "$MOCK_DIR/down"
"$PQT_BIN" status >/dev/null 2>"$SANDBOX/status2.err"
t12_rc2=$?
assert_rc 3 "$t12_rc2" "status should exit 3 when paseo ls --json fails"
rm -f "$MOCK_DIR/down"

exit 0
