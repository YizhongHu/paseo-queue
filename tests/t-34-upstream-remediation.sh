#!/bin/sh
# A failed immediate send must not forward upstream recovery commands.
set -u
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT INT TERM
export PASEO_QUEUE_NO_SPAWN=1
AGENT_UUID="a0000034-0000-0000-0000-000000000034"
seed_agent "$AGENT_UUID" "t34-agent" idle 0 0
mv "$SANDBOX/bin/paseo" "$SANDBOX/bin/paseo-mock"
cat > "$SANDBOX/bin/paseo" <<'EOF'
#!/bin/sh
if [ "$1" = send ]; then
    echo 'Start with: paseo daemon start --home "/Users/yizhonghu/.paseo"' >&2
    exit 1
fi
exec "$(dirname "$0")/paseo-mock" "$@"
EOF
chmod +x "$SANDBOX/bin/paseo"
for flag in --priority --interrupt; do
    "$PQT_BIN" add "$AGENT_UUID" probe "$flag" > "$SANDBOX/out" 2> "$SANDBOX/err"
    assert_rc 1 "$?" "send failure stays exit 1"
    assert_grep "$SANDBOX/err" 'message stays queued' "retain queue recovery guidance"
    grep -q 'paseo daemon start\|Start with:' "$SANDBOX/err" "$SANDBOX/out" \
        && fail "never relay upstream remediation from an immediate send"
done
assert_grep "$PASEO_QUEUE_HOME/$AGENT_UUID/dispatch.log" 'paseo daemon start' "keep evidence in diagnostics"
exit 0
