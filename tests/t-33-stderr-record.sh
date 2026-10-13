#!/bin/sh
# Preserve multiline evidence in one bounded, escaped log field.
set -u
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT INT TERM
export PASEO_QUEUE_NO_SPAWN=1 PASEO_QUEUE_LS_RETRY_DELAY=0
cp "$PQT_REPO_ROOT/tests/fixtures/uptime-eperm.stderr" "$MOCK_DIR/stderr"
cat > "$SANDBOX/bin/paseo" <<'EOF'
#!/bin/sh
cat "$MOCK_DIR/stderr" >&2
if [ -f "$MOCK_DIR/recover" ] && [ -f "$MOCK_DIR/tried" ]; then
    echo '[]'
    exit 0
fi
: > "$MOCK_DIR/tried"
exit 1
EOF
chmod +x "$SANDBOX/bin/paseo"
"$PQT_BIN" status > "$SANDBOX/out" 2> "$SANDBOX/err"
assert_rc 3 "$?" "snapshot failure remains exit 3"
assert_grep "$PASEO_QUEUE_HOME/daemon.log" 'uv_uptime returned EPERM' "retain more than the last JSON line"
python3 - "$PASEO_QUEUE_HOME/daemon.log" "$MOCK_DIR/stderr" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    lines = stream.read().splitlines()
with open(sys.argv[2], 'rb') as stream:
    expected = stream.read().decode('utf-8')
assert len(lines) == 2, lines
for line in lines:
    assert 'LS-FAIL attempt=' in line and ' rc=1 ' in line
    assert all(field in line for field in (' ms=', ' bytes=', ' load=', ' parse_error='))
    payload = line.split(' stderr=', 1)[1]
    assert json.loads('"' + payload + '"') == expected, payload
PY
assert_rc 0 "$?" "one escaped log record per attempt preserves all stderr"

# Recovery records must preserve the first failure too.
rm "$PASEO_QUEUE_HOME/daemon.log" "$MOCK_DIR/tried"
: > "$MOCK_DIR/recover"
"$PQT_BIN" status > "$SANDBOX/out" 2> "$SANDBOX/err"
assert_rc 0 "$?" "a successful retry clears the failure"
assert_grep "$PASEO_QUEUE_HOME/daemon.log" 'LS-RECOVERED.*prev_err=.*uv_uptime' "retain recovery evidence"
[ ! -s "$SANDBOX/err" ] || fail "recovered errors must not leak upstream advice"

# Cap input bytes, mark truncation, and tolerate invalid UTF-8/control bytes.
rm "$PASEO_QUEUE_HOME/daemon.log" "$MOCK_DIR/recover"
python3 - "$MOCK_DIR/stderr" <<'PY'
import sys
with open(sys.argv[1], 'wb') as stream:
    stream.write(b'uv_uptime EPERM\r\n\x00\xff' + b'x' * 20000 + b'END-MARKER')
PY
"$PQT_BIN" status > "$SANDBOX/out" 2> "$SANDBOX/err"
assert_rc 3 "$?" "oversized diagnostics do not break the command"
python3 - "$PASEO_QUEUE_HOME/daemon.log" <<'PY'
import sys
with open(sys.argv[1], 'rb') as stream:
    lines = stream.read().splitlines()
assert len(lines) == 2
for line in lines:
    assert b'uv_uptime EPERM\\r\\n\\u0000' in line
    assert b'[truncated]' in line and b'END-MARKER' not in line
    assert len(line) < 26000  # 4096 input bytes can expand sixfold when escaped.
PY
assert_rc 0 "$?" "diagnostics stay bounded and single-line"
exit 0
