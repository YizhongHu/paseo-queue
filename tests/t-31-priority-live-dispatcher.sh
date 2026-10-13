#!/bin/sh
# A dispatcher already in LINGER must not send an urgent caller's message.
set -u
. "$(dirname "$0")/common.sh"
setup
trap teardown EXIT INT TERM
export PQT_BIN
python3 - <<'PY'
import os
import pathlib
import subprocess
import signal
import time

root = pathlib.Path(os.environ['MOCK_DIR'])
home = pathlib.Path(os.environ['PASEO_QUEUE_HOME'])
queue = os.environ['PQT_BIN']
mock = pathlib.Path(os.environ['PATH'].split(os.pathsep)[0]) / 'paseo'
wrapper = root / 'gatebin'
wrapper.mkdir()
# Record acceptance first, then hold the urgent CLI before it can file sent/.
(wrapper / 'paseo').write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
root = pathlib.Path(os.environ['MOCK_DIR'])
rc = subprocess.call([os.environ['REAL_MOCK']] + sys.argv[1:])
if sys.argv[1] == 'send' and '--no-wait' not in sys.argv and (root / 'hold-normal').exists():
    (root / 'normal-accepted').touch()
    deadline = time.monotonic() + 20
    while not (root / 'normal-release').exists():
        if time.monotonic() > deadline:
            sys.exit(91)
        time.sleep(.02)
if sys.argv[1] == 'send' and '--no-wait' in sys.argv:
    (root / 'accepted').touch()
    deadline = time.monotonic() + 20
    while not (root / 'release').exists():
        if time.monotonic() > deadline:
            sys.exit(90)
        time.sleep(.02)
sys.exit(rc)
''')
(wrapper / 'paseo').chmod(0o755)
env = dict(os.environ, REAL_MOCK=str(mock),
           PATH=str(wrapper) + os.pathsep + os.environ['PATH'],
           PASEO_QUEUE_LINGER='20', PASEO_QUEUE_PRIORITY_GRACE='0')
# Count real dispatcher scans after acceptance. This makes the race window
# deterministic: do not release the caller until the dispatcher has revisited
# its queue several times. No product hooks or arbitrary send-delay guesses.
runner = root / 'paseo-queue-dispatch.py'
runner.write_text('''import os, pathlib, runpy, sys
ns = runpy.run_path(os.environ['PQT_BIN'], run_name='queue_under_test')
original = ns['message_files']
root = pathlib.Path(os.environ['MOCK_DIR'])
count = 0
def scans(path):
    global count
    result = original(path)
    if str(path).endswith('/pending') and (root / 'accepted').exists():
        count += 1
        (root / 'scans').write_text(str(count))
    return result
ns['cmd_dispatch'].__globals__['message_files'] = scans
sys.exit(ns['cmd_dispatch']([sys.argv[1]]))
''')

def wait_for(predicate, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError('timeout: ' + label)

def scans():
    try:
        return int((root / 'scans').read_text())
    except (OSError, ValueError):
        return 0

failures = []
for index, flag in enumerate(('--priority', '--interrupt')):
    for name in ('accepted', 'release', 'scans'):
        try:
            (root / name).unlink()
        except FileNotFoundError:
            pass
    uuid = 'a0000031-0000-0000-0000-%012d' % index
    with (root / 'agents.tsv').open('a') as stream:
        stream.write('%s\t%s\tt31-%d\tidle\t0\t0\n' % (uuid, uuid[:7], index))
    d = home / uuid
    subprocess.check_call([queue, 'add', uuid, 'warmup', '--quiet'],
                          env=dict(env, PASEO_QUEUE_NO_SPAWN='1'))
    dispatcher = subprocess.Popen(['python3', str(runner), uuid], env=env)
    urgent = None
    try:
        wait_for(lambda: (d / 'dispatch.log').exists() and
                 'LINGER' in (d / 'dispatch.log').read_text(), 'warm dispatcher LINGER')
        urgent = subprocess.Popen([queue, 'add', uuid, 'race-' + flag, flag], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        wait_for(lambda: (root / 'accepted').exists(), 'urgent accepted')
        wait_for(lambda: scans() >= 4, 'four live dispatcher scans')
        (root / 'release').touch()
        out, err = urgent.communicate(timeout=10)
        calls = [line for line in (root / 'calls.log').read_text().splitlines()
                 if line.startswith('send\t' + uuid + '\t')]
        # One warmup plus exactly one urgent send, with one final sent record.
        sends = len(calls) - 1
        records = [p for p in (d / 'sent').glob('*.msg')
                   if p.read_text().strip() == 'race-' + flag]
        deliveries = [p for p in (root / 'sent.d').glob('*')
                      if p.read_text().strip() == 'race-' + flag]
        print('%s: urgent send calls=%d, rc=%d, sent records=%d' %
              (flag, sends, urgent.returncode, len(records)), flush=True)
        if sends != 1 or urgent.returncode != 0 or len(records) != 1 or len(deliveries) != 1:
            print((d / 'dispatch.log').read_text(), flush=True)
            print(err.decode(), flush=True)
            failures.append('%s expected one urgent send; got %d (rc=%d)' %
                            (flag, sends, urgent.returncode))
        assert not list((d / 'pending').glob('*.msg')), 'message left pending'
    finally:
        (root / 'release').touch()
        if urgent is not None and urgent.poll() is None:
            urgent.terminate()
            urgent.wait(timeout=10)
        dispatcher.terminate()
        dispatcher.wait(timeout=10)
if failures:
    raise AssertionError('; '.join(failures))

# A dispatcher holding its lifetime lock inside another send cannot block
# either urgent flag indefinitely. Keep that send blocked until BOTH return.
uuid = 'a0000031-0000-0000-0000-000000000002'
with (root / 'agents.tsv').open('a') as stream:
    stream.write('%s\t%s\tt31-busy\tidle\t0\t0\n' % (uuid, uuid[:7]))
(root / 'hold-normal').touch()
(root / 'release').touch()
subprocess.check_call([queue, 'add', uuid, 'busy-normal', '--quiet'],
                      env=dict(env, PASEO_QUEUE_NO_SPAWN='1'))
dispatcher = subprocess.Popen([queue, '_dispatch', uuid], env=env)
try:
    wait_for(lambda: (root / 'normal-accepted').exists(), 'dispatcher mid-send')
    for flag in ('--priority', '--interrupt'):
        result = subprocess.run([queue, 'add', uuid, 'busy-' + flag, flag],
                                env=dict(env, PASEO_QUEUE_PRIORITY_GRACE='1'),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
        assert result.returncode == 0, result.stderr.decode()
        assert dispatcher.poll() is None, 'urgent caller killed dispatcher'
        assert not (root / 'normal-release').exists(), 'busy send released too early'
        assert len(list((home / uuid / 'sent').glob('*.msg'))) >= 1
        print(flag + ': returned while dispatcher remained mid-send', flush=True)
finally:
    (root / 'normal-release').touch()
    wait_for(lambda: len(list((home / uuid / 'sent').glob('*.msg'))) == 3,
             'all distinct busy-case messages filed')
    dispatcher.terminate()
    dispatcher.wait(timeout=10)
(root / 'hold-normal').unlink()

# Kill at publication, before PRIORITY-BEGIN/send. Catchable signals must
# release ownership; SIGKILL must leave an ordinary recoverable pending file.
crash_runner = root / 'paseo-queue-crash.py'
crash_runner.write_text('''import os, pathlib, runpy, sys, time
queue = os.environ['PQT_BIN']
ns = runpy.run_path(queue, run_name='queue_under_test')
original = ns['log_line']
def at_publication(agent_dir, event, detail=''):
    original(agent_dir, event, detail)
    if event == 'ENQ':
        pathlib.Path(os.environ['MOCK_DIR'], 'published').touch()
        time.sleep(30)
ns['cmd_add'].__globals__['log_line'] = at_publication
sys.argv[0] = queue
sys.exit(ns['cmd_add']([sys.argv[1], 'crash-before-send', '--priority', '--quiet']))
''')
for index, sig in enumerate((signal.SIGINT, signal.SIGTERM, signal.SIGKILL), 3):
    uuid = 'a0000031-0000-0000-0000-%012d' % index
    with (root / 'agents.tsv').open('a') as stream:
        stream.write('%s\t%s\tt31-crash%d\tidle\t0\t0\n' % (uuid, uuid[:7], index))
    try:
        (root / 'published').unlink()
    except FileNotFoundError:
        pass
    child = subprocess.Popen(['python3', str(crash_runner), uuid],
                             env=dict(env, PASEO_QUEUE_NO_SPAWN='1'),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        wait_for(lambda: (root / 'published').exists(), 'published before signal')
        child.send_signal(sig)
        child.wait(timeout=10)
        d = home / uuid
        assert len(list((d / 'pending').glob('*.msg'))) == 1, 'crash lost payload'
        if sig != signal.SIGKILL:
            assert not list((d / 'tmp').glob('priority.*.msg')), 'reservation leaked'
            assert 'PRIORITY-ABORT' in (d / 'dispatch.log').read_text()
        subprocess.run([queue, '_dispatch', uuid], check=True, timeout=10,
                       env=dict(env, PASEO_QUEUE_LINGER='0'))
        calls = [line for line in (root / 'calls.log').read_text().splitlines()
                 if line.startswith('send\t' + uuid + '\t')]
        assert len(calls) == 1, 'recovery must send exactly once'
        assert len(list((d / 'sent').glob('*.msg'))) == 1
        assert not list((d / 'pending').glob('*.msg'))
        assert not list((d / 'tmp').glob('priority.*.msg'))
        print('%s: pending payload recovered exactly once' % sig.name, flush=True)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=10)
PY
