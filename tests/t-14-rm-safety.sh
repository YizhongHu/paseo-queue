#!/bin/sh
# tests/t-14-rm-safety.sh: two independent-review findings against `rm` and
# die()'s diagnostics:
#   (A) `rm <agent> <msg>` must reject any target containing a path
#       separator (traversal like "../../x" or an absolute path) instead of
#       constructing "$pending_dir/$target" and deleting whatever that
#       resolves to outside pending/. A canary file planted just outside the
#       agent's pending/ dir proves it is never touched, and a legitimate
#       bare-filename `rm` of a real pending message still works.
#   (B) die()'s diagnostics must use printf, not echo, so a user-supplied
#       agent query containing a backslash escape sequence (e.g. "\n") is
#       never mangled/truncated by macOS /bin/sh's escape-interpreting echo
#       builtin -- the literal two characters "\" "n" must survive verbatim
#       on stderr, on one line.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_UUID="a0000014-0000-0000-0000-000000000014"
AGENT_NAME="t14-agent"
seed_agent "$AGENT_UUID" "$AGENT_NAME" idle 0 0

dp_dir="$PASEO_QUEUE_HOME/$AGENT_UUID"

PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_UUID" "t14 real message"
assert_rc 0 "$?" "add should enqueue the real message"

t14_msgname=""
for t14_f in "$dp_dir/pending"/*.msg; do
    [ -e "$t14_f" ] || continue
    t14_msgname="${t14_f##*/}"
done
[ -n "$t14_msgname" ] || fail "expected exactly one pending message before the rm attempts"

# --- (A1) relative traversal target must be rejected, canary untouched ---

CANARY="$PASEO_QUEUE_HOME/canary.txt"
printf 'do not delete me\n' > "$CANARY"

t14_out="$("$PQT_BIN" rm "$AGENT_UUID" "../../canary.txt" 2>&1)"
t14_rc=$?
assert_rc 1 "$t14_rc" "rm with a path-separator target should be rejected, not attempted"
[ -e "$CANARY" ] || fail "SECURITY: rm traversal target deleted a file outside pending/: $CANARY"
printf '%s\n' "$t14_out" | grep -q "invalid message name" || fail "rejection should explain the target is invalid"

# --- (A2) absolute-path target must also be rejected ---

CANARY2="$SANDBOX/canary2.txt"
printf 'do not delete me either\n' > "$CANARY2"

"$PQT_BIN" rm "$AGENT_UUID" "$CANARY2" >/dev/null 2>&1
t14_rc2=$?
assert_rc 1 "$t14_rc2" "rm with an absolute-path target should be rejected"
[ -e "$CANARY2" ] || fail "SECURITY: rm absolute-path target deleted a file outside pending/: $CANARY2"

# --- (A3) the real pending message must be untouched by the rejected
#          attempts above, and a legitimate bare-filename rm must still work.

[ -e "$dp_dir/pending/$t14_msgname" ] || fail "real pending message should be untouched by the rejected rm attempts"

"$PQT_BIN" rm "$AGENT_UUID" "$t14_msgname"
assert_rc 0 "$?" "rm with a legitimate bare filename should still succeed"
[ -e "$dp_dir/pending/$t14_msgname" ] && fail "legitimate rm should have removed the real pending message"

# --- (B) die()'s diagnostics preserve backslash sequences verbatim ---

t14_err="$("$PQT_BIN" add 'weird\nagent-does-not-exist' "msg" 2>&1 >/dev/null)"
t14_err_rc=$?
assert_rc 2 "$t14_err_rc" "resolving a nonexistent agent should exit 2"

# printf, unlike an escape-interpreting echo, never turns the two literal
# characters backslash+n into a real newline: the whole diagnostic must be
# exactly one line, and that line must contain the literal substring.
t14_err_lines="$(printf '%s\n' "$t14_err" | wc -l | tr -d ' ')"
assert_eq "$t14_err_lines" "1" "die()'s diagnostic must stay on one line (echo would split it on a literal \\n)"
case "$t14_err" in
    *'weird\nagent-does-not-exist'*) : ;;
    *) fail "die() must preserve the literal backslash-n verbatim, got: $t14_err" ;;
esac

exit 0
