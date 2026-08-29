# paseo-queue

`paseo-queue` is an ordered, fire-and-forget FIFO prompt queue for routine
and non-emergency coordination with Paseo-managed agents. It lets any caller
`add` a follow-up message, and a per-agent background dispatcher
auto-delivers each queued message, strictly in order, the moment that agent
goes idle with no pending permission request. Each agent gets its own queue
and dispatcher, so follow-ups to different agents are delivered in parallel
while follow-ups to the *same* agent are always delivered one at a time, in
enqueue order.

This exists because Paseo has no built-in "deliver at the agent's next
convenience" primitive. Routine prompts use this queue to preserve FIFO order
and permission holds. When a message *is* urgent enough to interrupt, use
`add --interrupt` rather than a bare `paseo send`: the queue performs the send
itself, so the message is recorded and cannot later be delivered a second time
by a dispatcher. `paseo wait` is a broadcast release shared by every waiter,
not a queue.

## Prerequisites

- macOS or another POSIX `sh` environment.
- A working, configured [`paseo`](https://github.com/getpaseo/paseo) CLI and
  daemon.
- `python3`, used for small JSON parsing operations.
- `~/.local/bin` on `PATH`.

## Install

```sh
git clone https://github.com/YizhongHu/paseo-queue.git
cd paseo-queue
./install.sh
paseo-queue --help
```

`install.sh` is idempotent (safe to re-run) and touches exactly four
locations:

- `~/.local/bin/paseo-queue` — a symlink to this repo's `bin/paseo-queue`,
  put on `PATH`.
- `~/.claude/skills/paseo-queue/SKILL.md` — copy of `skills/paseo-queue/SKILL.md`.
- `~/.codex/skills/paseo-queue/SKILL.md` — copy of `skills/paseo-queue/SKILL.md`.
- `~/.agents/skills/paseo-queue/SKILL.md` — copy of `skills/paseo-queue/SKILL.md`.

It then verifies the install by running `command -v paseo-queue` and
`paseo-queue --help`, and prints `SUCCESS`/`FAILED` accordingly.

## Quick start

Queue a routine follow-up without interrupting the recipient:

```sh
paseo-queue add <agent> "routine follow-up"
```

Messages can also come from a file. Add `--wait` only when your next step
depends on the message having been dispatched:

```sh
paseo-queue add <agent> --file handoff.md
paseo-queue add <agent> "deliver before my next step" --wait
```

When a message is important enough to interrupt the agent's current work,
interrupt *through* the queue:

```sh
paseo-queue add <agent> "urgent: stop before the deploy step" --interrupt
```

That delivers immediately — skipping both the wait for the agent to go idle
and the pending-permission hold — and files the message in `sent/`.

Prefer it over a bare `paseo send`. A direct send happens outside the queue,
so the queue has no record of it: if the same message was also queued, a
dispatcher delivers it a **second time** later, and the sender has no way to
see that coming. The queue is still the default for routine and non-emergency
coordination.

## Skill backups

`skills/paseo-queue/SKILL.md` is the single canonical source for the
installed skill: `install.sh` reads it directly and copies it into every
skill root (see Install above). Running `./install.sh` restores it if a
Paseo-managed refresh ever erases the installed copies.

`skills/paseo/SKILL.md` and `skills/paseo-message-agent/SKILL.md` are tracked
backups of the user's personal-skill edits for those two unrelated skills
(both cross-reference `paseo-queue`). They are not installed by `install.sh`
and are not touched by it; if ever needed, copy them back to the affected
skill root manually.

## Usage

```
paseo-queue <subcommand> [args]
```

### Subcommands

- **`add <agent> [text|--file <path>|stdin] [--wait] [--wait-timeout <seconds>] [--quiet] [--interrupt]`**
  Enqueue a message for delivery to `<agent>`. Message content comes from
  exactly one source: a single `[text]` argument, `--file <path>`, or piped
  stdin (mutually exclusive; if none is given and stdin is a tty, this is
  an error). Flags and `[text]` may appear in any order/interspersed; a
  second stray positional argument is an error (quote a multi-word message
  into one argument). Dash-leading text is accepted inline when it contains
  whitespace (including markdown bullets); use `--` only for a whitespace-free
  token such as `-v`.
  On success it prints one receipt line naming the queued file, so a caller
  has a concrete artefact to check rather than only the absence of an error:
  ```
  paseo-queue: enqueued 2d4c857 pending/1787883101-0099103-0000.msg
  ```
  Exit `0` there means *enqueued*, not delivered; `--wait` adds a second
  line reporting delivery. `--quiet` suppresses both (errors still print).

  `--interrupt` delivers that message immediately — skipping both the wait for
  the agent to become idle and the pending-permission hold — and files it in
  `sent/`. Prefer it over a bare `paseo send` for anything you would otherwise
  queue: the queue performs the send itself, so the message is recorded once
  and no dispatcher can deliver it again. A direct `paseo send` is invisible to
  the queue, so a message that was also queued arrives twice. `--interrupt`
  jumps any backlog, which is why its receipt reads `interrupted` rather than
  `delivered`; a failed immediate send leaves the message queued and exits
  nonzero.

- **`ls`**
  List every known agent's queue: pending/sent/failed counts and the
  pending message filenames.

- **`rm <agent> <msg|--all>`**
  Delete one pending message (by filename) or all pending messages for
  `<agent>`. Every removed filename is printed, plus a count for `--all`, so
  a destructive default is never silent. After `--all`, if the agent's state
  directory is then fully empty (no pending/sent/failed/tmp files, no lock)
  and the agent is orphaned (absent from `paseo ls`), the directory itself is
  removed.

- **`status`**
  Show, per agent: state (from the dispatcher-owned state file),
  pending/sent/failed counts, and dispatcher pid + liveness. Agents absent
  from the current `paseo ls` snapshot are marked ORPHANED. Emits stderr
  WARN lines when an agent has pending messages but no live dispatcher, or
  when its state is `holding-permission`. Exits 3 if `paseo ls --json`
  itself fails (daemon unreachable).

- **`drain <agent> [--quiet]`**
  Force-(re)start the dispatcher for `<agent>` (ensures its state
  directories exist, then spawns the dispatcher; safe to call whether or
  not one is already running).

- **`stop <agent> [--quiet]`**
  Send SIGTERM to the live dispatcher for `<agent>`. The queue itself
  (pending/sent/failed) is left untouched.

- **`log <agent> [-n N] [-f]`**
  Show the last N lines (default 20) of the dispatch log for `<agent>`, or
  follow it live with `-f`.

- **`help` / `--help` / `-h`**
  Show the built-in help message (the authoritative reference for exact
  flag syntax).

### Delivery modes

- **Default (fire-and-forget):** `add` returns `0` immediately once the
  message is atomically enqueued and the dispatcher is (re)spawned, printing
  an `enqueued <shortid> pending/<file>` receipt. It does not wait for
  delivery, and the receipt says `enqueued` rather than `delivered` for
  exactly that reason.
- **`--wait`:** blocks until the message leaves `pending/`:
  - exits `0` once the message is observed in `sent/`;
  - exits `1` once it is observed in `failed/`, or once the dispatcher
    state becomes `halted-closed`, `halted-failed`, or `stalled-daemon`
    (the message stays queued in all three cases);
  - exits `4` if `--wait-timeout <seconds>` elapses first (the message
    stays queued; `--wait-timeout` implies `--wait`).
- **`--interrupt`:** delivers that message immediately, bypassing both the
  wait for the agent to become idle and the pending-permission hold, then
  files it in `sent/` before returning. Prints a second receipt line reading
  `interrupted <shortid> <file>` rather than `delivered`, because it also
  jumps any queued backlog — the wording is deliberate so that a log reader
  can see FIFO was broken on purpose. Because the queue performs the send
  itself, the message is recorded once and no dispatcher will ever deliver it
  again; this is the difference from a bare `paseo send`, which the queue
  cannot see. If the immediate send fails the message is **left queued** for
  normal delivery, a dispatcher is spawned, and the exit status is `1` — the
  caller loses the immediacy, never the message. Cannot be combined with
  `--wait`, which would have nothing left to wait for.

### Agent argument forms

`add`/`ls`/`rm`/`status`/`log`/`stop`/`drain` all resolve `<agent>` the same
way, from a single `paseo ls --json` snapshot:

- an **exact** agent name (never a name prefix — names may contain spaces);
- a unique agent-id **prefix** (this subsumes the 7-char shortId and the
  full 36-char UUID);
- an ambiguous query (matches more than one agent) exits **2**, listing
  every candidate on stderr.

`rm`/`ls`/`log`/`stop`/`status` additionally accept a full 36-char UUID that
matches an existing `$PASEO_QUEUE_HOME` state directory even when the agent
no longer appears in `paseo ls` (the "orphan" escape hatch). This never
applies to `add`/`drain`, which require a live agent.

### Dispatch log events

`paseo-queue log <agent>` shows the per-agent `dispatch.log`. Every line is
`<timestamp> [<pid>] <EVENT> <detail>`. The vocabulary, since these are what
you actually read when diagnosing a delivery:

| Event | Meaning |
|-------|---------|
| `ENQ` | A message was enqueued. Written by `add`, not by the dispatcher. |
| `START` | A dispatcher acquired the lock and began work. |
| `SKIP` | A dispatcher found the lock held by a live holder and exited without doing anything. Normal and expected — every `add` spawns one. |
| `STEAL` | A dispatcher found a lock whose recorded pid was dead and reclaimed it. |
| `WAIT-BUSY` | The agent is busy; the dispatcher is holding the message and waiting for idle. Rate-limited by `PASEO_QUEUE_HOLD_LOG_EVERY`. |
| `HOLD-PERM` | The agent has a pending permission request; delivery is held. Same rate limit. |
| `SEND-BEGIN` / `SEND-OK` / `SEND-FAIL` | A normal queued delivery starting, succeeding (with byte count), or failing. |
| `RETRY` | A transient send failure is being retried, with attempt count. |
| `HALT` | The dispatcher stopped on a terminal condition — see the state file for which (`halted-closed`, `halted-failed`, `stalled-daemon`). |
| `INTERRUPT-BEGIN` / `INTERRUPT-OK` / `INTERRUPT-FAIL` | An `add --interrupt` delivery. `INTERRUPT-OK` means the message was sent and filed in `sent/`, so no dispatcher will re-deliver it. `INTERRUPT-FAIL` means the message was left queued for normal delivery. |
| `INTERRUPT-RACE` | An `--interrupt` proceeded while a dispatcher was still inside a send for the same agent, after waiting `PASEO_QUEUE_INTERRUPT_GRACE` seconds. Two prompts may have reached the agent close together. |
| `CANCEL` | A pending message was removed by `rm`, or vanished before its send. |
| `LINGER` / `REACQUIRE` / `YIELD` / `EXIT` | Dispatcher lifecycle: idling on an empty queue, resuming because work arrived, standing down because another dispatcher took the lock, and exiting (with a reason). |
| `STOP` | A `stop` command SIGTERM'd this dispatcher, naming the pid. |
| `MOVE-FAILED` / `FATAL` | The dispatcher could not file a delivered message, or hit an unexpected error. Both are worth investigating; neither should occur in normal operation. |

## State layout

Each agent gets one state directory `$PASEO_QUEUE_HOME/<full-uuid>/`
(default `PASEO_QUEUE_HOME` is `~/.paseo-queue`):

```
$PASEO_QUEUE_HOME/<uuid>/
  pending/        # queued messages not yet delivered, FIFO filenames
  sent/           # messages successfully delivered (moved from pending/)
  failed/         # messages that exhausted send retries, plus a .err sidecar
  tmp/            # staging area for atomic writes (enqueue, state updates)
  lock/           # mkdir-based lock directory; lock/pid holds the holder's pid
  dispatch.log    # this agent's dispatcher event log (rotates at 5 MiB)
  state           # one-word dispatcher state (see recovery runbook below)
  agent.name      # cached "<shortId> <name>" resolved at enqueue time
```

## Environment knobs

All variables are test-overridable; every internal default matches the
value below unless overridden.

| Variable                       | Default             | Meaning |
|---------------------------------|----------------------|---------|
| `PASEO_QUEUE_HOME`               | `$HOME/.paseo-queue` | State root directory. |
| `PASEO_QUEUE_LINGER`             | `10`                 | Dispatcher idle linger, seconds, before it exits an empty queue. |
| `PASEO_QUEUE_WAIT_TIMEOUT`       | `60`                 | Timeout passed to the dispatcher's internal `paseo wait` call. |
| `PASEO_QUEUE_MAX_BYTES`          | `262144`             | Max enqueued message size in bytes. |
| `PASEO_QUEUE_INTERRUPT_GRACE`    | `10`                 | Seconds `add --interrupt` waits for an in-flight dispatcher send before proceeding anyway. |
| `PASEO_QUEUE_SEND_RETRIES`       | `5`                  | Transient send-failure retry count before a message is moved to `failed/`. |
| `PASEO_QUEUE_DAEMON_RETRIES`     | `15`                 | Transient daemon-unreachable retry count before the dispatcher halts as `stalled-daemon`. |
| `PASEO_QUEUE_HOLD_LOG_EVERY`     | `300`                | Rate limit (seconds) for repeated `HOLD-PERM` log lines. |
| `PASEO_QUEUE_NO_SPAWN`           | `0`                  | Set to `1` to disable dispatcher auto-spawn (tests only). |
| `PASEO_QUEUE_BACKOFF_SCALE`      | `1`                  | Multiplier for `_dispatch` backoff sleeps, nonnegative integer (tests only). |

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Ok. |
| `1`  | Error (validation failure, missing dispatcher, no message, a `--wait`ed message reaching `failed/`/`halted-*`, a failed `--interrupt` whose message stays queued, etc.). |
| `2`  | Agent resolution failure (not found or ambiguous). |
| `3`  | Daemon unreachable (`paseo ls`/`paseo inspect` failed). |
| `4`  | `add --wait-timeout` elapsed (message remains queued). |

## Recovery runbook

Run `paseo-queue status` first — it prints each agent's current `state` and
flags the two conditions below with a stderr `WARN` line.

| Symptom | `state` value | Action |
|---|---|---|
| Dispatcher paused, waiting on a permission prompt | `holding-permission` | Approve (or deny) the pending permission in the Paseo app; the dispatcher resumes on the next `paseo wait` release. |
| Agent was archived/closed while messages were queued | `halted-closed` | The queue is preserved untouched. Either unarchive the agent and run `paseo-queue drain <agent>` to resume delivery, or `paseo-queue rm <agent> --all` to discard the backlog. |
| A message exhausted its send retries | `halted-failed` | Inspect `failed/<msg>.err` (rc + stderr tail) for the message under `$PASEO_QUEUE_HOME/<uuid>/failed/`. Re-enqueue its content with `paseo-queue add <agent> --file <path-to-message>`, then run `paseo-queue drain <agent>` to resume. |
| Repeated daemon-unreachable failures | `stalled-daemon` | The dispatcher retried `PASEO_QUEUE_DAEMON_RETRIES` times (default 15, backing off 10s/30s/60s.../ ~13 minutes total) and gave up with the queue intact. Restart/reconnect the Paseo daemon, then run `paseo-queue drain <agent>`. |
| Messages queued but nothing is being delivered | (any/missing, `pending > 0` with no live dispatcher) | Run `paseo-queue drain <agent>` — `status` prints a `WARN` for exactly this condition. |

## Caveats

- **FIFO ordering is per enqueuing process.** Ordering is strict FIFO for
  messages added by the same process. Across different processes that
  enqueue to the same agent within the same wall-clock second, delivery
  order falls back to pid order (filenames are
  `<epoch10>-<pid7>-<seq4>.msg`, glob-sorted under `LC_ALL=C`) — this is a
  documented, not a bug.
- **Stale-lock detection has a narrow pid-reuse residual risk.** Lock
  liveness is checked via `kill -0` plus a `ps -p <pid> -o command=`
  substring match on `paseo-queue` (no `flock` on macOS; the check is
  deliberately conservative). If a dispatcher
  dies uncleanly and the OS later reuses that exact pid for an unrelated
  `paseo-queue` process before the stale lock is broken, the lock can
  appear live for longer than it should. The only consequence is a delayed
  dispatch resumption — messages are never double-sent, because delivery
  itself is always guarded by the same lock.
- **A backwards system clock jump can reorder pending messages.** Filenames
  embed the epoch second, and delivery pops the lexicographically-first
  filename, so a clock that jumps backwards between two enqueues can make
  the later message sort before the earlier one.
- **Interrupting bypasses queued ordering, by design.** `add --interrupt`
  on an agent with messages in `pending/` delivers ahead of them. That is the
  point, and the `interrupted` receipt makes it visible; but if ordering
  matters more than immediacy, queue normally.
- **A bare `paseo send` is invisible to the queue.** It delivers out of order
  like an interrupt, but leaves no record, so a message that was *also*
  queued will be delivered a second time when a dispatcher reaches it. Use
  `add --interrupt` for anything you would otherwise queue; reserve plain
  `paseo send` for cases where you are deliberately not queueing at all.

## Disposability

`paseo-queue` is an explicit stopgap, not a permanent tool. It exists only
until the daemon-owned queue feature upstream
([getpaseo/paseo#3797](https://github.com/getpaseo/paseo/pull/3797)) merges
and ships in a release. Once that happens, uninstall by:

1. Removing the `~/.local/bin/paseo-queue` symlink.
2. Removing the installed skill directories: `~/.claude/skills/paseo-queue/`,
   `~/.codex/skills/paseo-queue/`, `~/.agents/skills/paseo-queue/`.
3. Deleting this repository.

`$PASEO_QUEUE_HOME` (default `~/.paseo-queue`) holds only queue state (
pending/sent/failed messages, locks, and logs) — no irreplaceable data, so
it can be deleted along with the rest, or left behind harmlessly.
