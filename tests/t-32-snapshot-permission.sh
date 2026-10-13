#!/bin/sh
# A failed sandbox sysctl is not evidence of a dead daemon.
set -u
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT INT TERM
export PASEO_QUEUE_NO_SPAWN=1 PASEO_QUEUE_LS_RETRY_DELAY=0
AGENT_UUID="a0000032-0000-0000-0000-000000000032"
seed_agent "$AGENT_UUID" "t32-agent" idle 0 0
mv "$SANDBOX/bin/paseo" "$SANDBOX/bin/paseo-mock"
cat > "$SANDBOX/bin/paseo" <<'EOF'
#!/bin/sh
if [ "$1" = ls ]; then
    cat "$MOCK_DIR/stderr" >&2
    [ -f "$MOCK_DIR/success" ] || exit 1
fi
exec "$(dirname "$0")/paseo-mock" "$@"
EOF
chmod +x "$SANDBOX/bin/paseo"
cp "$PQT_REPO_ROOT/tests/fixtures/uptime-eperm.stderr" "$MOCK_DIR/stderr"

check_permission() {
    "$PQT_BIN" "$@" > "$SANDBOX/out" 2> "$SANDBOX/err"
    assert_rc 3 "$?" "permission failures retain the snapshot failure exit code"
    assert_grep "$SANDBOX/err" "permission" "name the permission problem"
    assert_grep "$SANDBOX/err" "sandbox" "name the sandbox cause"
    assert_grep "$SANDBOX/err" "not a daemon fault" "do not diagnose an outage"
    assert_grep "$SANDBOX/err" "retry with escalated permissions or request full-access" "give actionable guidance"
    grep -q 'paseo daemon start\|Start with:' "$SANDBOX/err" "$SANDBOX/out" \
        && fail "never relay upstream remediation"
    return 0
}
check_permission add "$AGENT_UUID" probe
check_permission status
assert_grep "$PASEO_QUEUE_HOME/daemon.log" 'uv_uptime returned EPERM' "retain the real cause"

# Each requested signature works independently, with the same rc as outages.
for signature in EPERM 'operation not permitted' 'not permitted'; do
    printf '%s\n' "$signature" > "$MOCK_DIR/stderr"
    check_permission add "$AGENT_UUID" probe
done

# The SAME return code with connection-refused stderr remains a daemon failure.
printf '%s\n' 'connect: connection refused' > "$MOCK_DIR/stderr"
for command in add status; do
    if [ "$command" = add ]; then
        "$PQT_BIN" add "$AGENT_UUID" probe > "$SANDBOX/out" 2> "$SANDBOX/err"
    else
        "$PQT_BIN" status > "$SANDBOX/out" 2> "$SANDBOX/err"
    fi
    assert_rc 3 "$?" "connection failure remains exit 3"
    assert_grep "$SANDBOX/err" 'daemon unreachable' "real connection failures remain daemon problems"
    grep -q 'escalated\|full-access' "$SANDBOX/err" && fail "do not relabel all failures"
done

# Stderr alone on a successful snapshot is not a permission failure.
printf '%s\n' EPERM > "$MOCK_DIR/stderr"
: > "$MOCK_DIR/success"
"$PQT_BIN" add "$AGENT_UUID" probe > "$SANDBOX/out" 2> "$SANDBOX/err"
assert_rc 0 "$?" "successful snapshots must still enqueue"
exit 0
