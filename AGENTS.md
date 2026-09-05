# Contributor rules for paseo-queue

- **Python 3 stdlib only.** `bin/paseo-queue` is a single-file Python 3
  program. No third-party packages, no `requirements.txt`, no venv: the tool
  must run from a bare `python3` on `PATH`.
- **Target Python 3.8.** The reference environment reports
  `Python 3.8.3`. Do not use 3.9+ syntax or APIs — no `dict | dict` merge
  operator, no `match` statements, no builtin generics in annotations
  (`list[str]`), no `str.removeprefix`/`removesuffix`.
- **The on-disk layout is a compatibility surface, not an implementation
  detail.** `$PASEO_QUEUE_HOME/<uuid>/{pending,sent,failed,tmp}/` plus
  `state`, `agent.name`, `dispatch.log` and `lock/pid` are read and written
  by other versions of this tool, including the shell implementation this
  one replaced. Changing the layout breaks rollback. Don't.
- **No `flock`.** Not available on macOS. Locking is `mkdir` plus pid-file
  liveness checks; see the dispatcher section of README.md for the protocol.
- **The dispatcher must be its own session leader.** Spawn it with
  `start_new_session=True`. Inheriting the caller's process group is what
  caused issue #4: short-lived agent shells took their dispatchers down with
  them and stranded messages silently for ~21 hours.
- **Never discard the daemon's stderr.** `paseo ls --json` fails
  intermittently and those failures are hard to reproduce; the tool used to
  route that stderr to DEVNULL, destroying the evidence on every occurrence.
  Failures go to `$PASEO_QUEUE_HOME/daemon.log` with exit code, duration,
  byte count, load average and stderr. Diagnostics are best effort and must
  never be able to fail a command.
- **A malformed daemon response is a daemon fault, not an empty fleet.**
  Parsing failure must surface as exit 3, never as a silently empty agent
  list — that is how a truncated read masqueraded as `no agent matches`.
- **A message in `pending/` must always have a dispatcher coming for it.**
  This is what makes the queue recoverable: `add` spawns a dispatcher, so any
  death still leaves the message deliverable. `add --interrupt` deliberately
  does NOT spawn one up front, because it would race the interrupt for the
  same file — so it carries the obligation itself, via a `finally` that
  spawns a dispatcher whenever the message is still in `pending/` as the
  function unwinds, plus SIGINT/SIGTERM handlers so a process-group teardown
  reaches that `finally`. Removing either half reintroduces a real defect: a
  killed interrupt once stranded a message for 14 hours, its log frozen at
  `INTERRUPT-BEGIN` with nothing following. SIGKILL cannot be caught and is
  the accepted residual; such a message is recovered by the next `add` or
  `drain` for that agent.
- **An interrupt must file its message as sent.** `add --interrupt` performs
  the `paseo send` itself and then moves the message into `sent/`. That move
  is what makes the delivery single: a message left in `pending/` after a
  successful send will be delivered a SECOND time by the next dispatcher.
  This is exactly the trap a bare `paseo send` falls into, and the reason
  `--interrupt` exists. If you change the interrupt path, the invariant to
  preserve is *sent exactly once, and recorded* — not merely *sent*.
- **Install signal handlers before acquiring the lock.** A signal arriving
  between `acquire_lock` and the `START` log line otherwise strands `lock/`
  holding a dead pid with no log line. The path that fails to acquire the
  lock must restore the original handlers before exiting, or it will clobber
  the state file of the live dispatcher that legitimately holds the lock.
- **Whole-second epoch in message filenames.** Filenames are
  `<epoch10>-<pid7>-<seq4>.msg` and their `LC_ALL=C` glob order is what
  makes delivery FIFO. Keep the fixed widths.
- **Env knobs are named `PASEO_QUEUE_*` externally, `PQ_*` internally.**
  Every user/test-facing override is `PASEO_QUEUE_HOME`,
  `PASEO_QUEUE_LINGER`, etc. (see README.md for the full table);
  `bin/paseo-queue` reads each of those once at startup into an internal
  module-level constant that the rest of the program uses. Keep this split when adding a new knob: add the `PASEO_QUEUE_*`
  read-with-default at the top of the file, use only the `PQ_*` name
  everywhere else, and document the new `PASEO_QUEUE_*` name in both
  `usage()` and README.md.
- **Run `tests/run-tests.sh` before every commit.** It runs every
  `tests/t-*.sh` and prints a `PASS`/`FAIL` line per test plus a final
  count; a failing test suite blocks the commit. Tests are self-contained:
  each `t-*.sh` sources `tests/common.sh`, which builds a fresh `mktemp`
  sandbox per test (its own `PASEO_QUEUE_HOME`, its own mock `paseo` shim
  placed first on `PATH`, and fast dispatcher knobs), so tests never touch
  a real `~/.paseo-queue` or a real Paseo daemon and can run in any order.
- **This tool is disposable.** It exists only until
  [getpaseo/paseo#3797](https://github.com/getpaseo/paseo/pull/3797) ships
  upstream. Do not over-engineer; prefer the simplest correct
  implementation of the design plan.
- **Never put backticks in git commit messages.** Backticks trigger shell
  command substitution and can silently corrupt or truncate the message.
  For multi-line commit messages, use `git commit -F -` with a quoted
  heredoc, e.g.:

  ```sh
  git commit -F - <<'EOF'
  feat: some change

  Longer explanation here.
  EOF
  ```
