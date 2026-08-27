#!/bin/sh
# tests/t-15-add-arg-parsing.sh: regression coverage for add's interspersed
# argument scan, especially literal messages that begin with a dash.
set -u

. "$(dirname "$0")/common.sh"

setup
trap teardown EXIT INT TERM

AGENT_A="a0000015-0000-0000-0000-00000000000a"
AGENT_B="a0000015-0000-0000-0000-00000000000b"
AGENT_C="a0000015-0000-0000-0000-00000000000c"
AGENT_D="a0000015-0000-0000-0000-00000000000d"
AGENT_E="a0000015-0000-0000-0000-00000000000e"
AGENT_F="a0000015-0000-0000-0000-00000000000f"
AGENT_G="a0000015-0000-0000-0000-000000000010"
AGENT_H="a0000015-0000-0000-0000-000000000011"
AGENT_I="a0000015-0000-0000-0000-000000000012"
AGENT_J="a0000015-0000-0000-0000-000000000013"

seed_agent "$AGENT_A" "t15-a-agent" idle 0 0
seed_agent "$AGENT_B" "t15-b-agent" idle 0 0
seed_agent "$AGENT_C" "t15-c-agent" idle 0 0
seed_agent "$AGENT_D" "t15-d-agent" idle 0 0
seed_agent "$AGENT_E" "t15-e-agent" idle 0 0
seed_agent "$AGENT_F" "t15-f-agent" idle 0 0
seed_agent "$AGENT_G" "t15-g-agent" idle 0 0
seed_agent "$AGENT_H" "t15-h-agent" idle 0 0
seed_agent "$AGENT_I" "t15-i-agent" idle 0 0
seed_agent "$AGENT_J" "t15-j-agent" running 0 0

t15_case_a() (
    t15_text='- first bullet
- second bullet'
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_A" "$t15_text" >/dev/null 2>&1
    assert_rc 0 "$?" "inline markdown bullet should be accepted"
    t15_msg=""
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_A"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
        t15_msg="$t15_f"
    done
    assert_eq "$t15_pending" "1" "inline markdown bullet should stage exactly one message"
    printf '%s\n' "$t15_text" > "$SANDBOX/expected-a"
    cmp -s "$t15_msg" "$SANDBOX/expected-a" || fail "inline markdown bullet should preserve both lines plus one trailing newline"
)

t15_case_b() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_B" "-leading dash message" >/dev/null 2>&1
    assert_rc 0 "$?" "inline leading-dash message should be accepted"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_B"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "1" "inline leading-dash message should stage one message"
)

t15_case_c() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_C" -- "-v" >/dev/null 2>&1
    assert_rc 0 "$?" "-- should allow a literal leading-dash message"
    t15_msg=""
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_C"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
        t15_msg="$t15_f"
    done
    assert_eq "$t15_pending" "1" "-- escape should stage exactly one message"
    printf '%s\n' '-v' > "$SANDBOX/expected-c"
    cmp -s "$t15_msg" "$SANDBOX/expected-c" || fail "-- escape should stage literal -v plus one trailing newline"
)

t15_case_d() (
    for t15_opt in --waitt --wait-timeout=5 --wait_timeout; do
        PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_D" "$t15_opt" >/dev/null 2>&1
        assert_rc 1 "$?" "genuine unknown option $t15_opt should be rejected"
    done
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_D"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "unknown options must not stage a message"
)

t15_case_e() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_E" --file >/dev/null 2>&1
    assert_rc 1 "$?" "--file without a path should be rejected"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_E"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "missing --file path must not stage a message"
)

t15_case_f() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_F" --wait-timeout >/dev/null 2>&1
    assert_rc 1 "$?" "--wait-timeout without a value should be rejected"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_F"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "missing timeout value must not stage a message"
)

t15_case_g() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_G" --wait-timeout abc >/dev/null 2>&1
    assert_rc 1 "$?" "non-numeric --wait-timeout should be rejected"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_G"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "invalid timeout value must not stage a message"
)

t15_case_h() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_H" one two >/dev/null 2>&1
    assert_rc 1 "$?" "two bare positionals should be rejected"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_H"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "two bare positionals must not stage a message"
)

t15_case_i() (
    t15_file="$SANDBOX/file-i"
    printf '%s\n' file-text > "$t15_file"
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_I" inline --file "$t15_file" >/dev/null 2>&1
    assert_rc 1 "$?" "inline text and --file should be mutually exclusive"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_I"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "0" "mutually exclusive message sources must not stage a message"
)

t15_case_j() (
    PASEO_QUEUE_NO_SPAWN=1 "$PQT_BIN" add "$AGENT_J" --wait "msg" --wait-timeout 1 >/dev/null 2>&1
    assert_rc 4 "$?" "flag before text should parse successfully and time out while queued"
    t15_pending=0
    for t15_f in "$PASEO_QUEUE_HOME/$AGENT_J"/pending/*.msg; do
        [ -e "$t15_f" ] || continue
        t15_pending=$((t15_pending + 1))
    done
    assert_eq "$t15_pending" "1" "flag-before-text timeout should leave the message pending"
)

t15_failed=0
t15_case_a || t15_failed=1
t15_case_b || t15_failed=1
t15_case_c || t15_failed=1
t15_case_d || t15_failed=1
t15_case_e || t15_failed=1
t15_case_f || t15_failed=1
t15_case_g || t15_failed=1
t15_case_h || t15_failed=1
t15_case_i || t15_failed=1
t15_case_j || t15_failed=1

exit "$t15_failed"
