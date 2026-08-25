# Contributor rules for paseo-queue

- **POSIX sh only.** Target macOS `/bin/sh`, which is bash 3.2 running in
  `sh` mode. Do not use bashisms (arrays, `[[ ]]`, `local`, process
  substitution, etc.).
- **No `jq`.** Not guaranteed to be installed; use `python3` one-liners for
  JSON parsing/generation instead (see below).
- **No `flock`.** Not available on macOS. Locking is implemented with
  `mkdir` + pid-file liveness checks (see the design plan for the exact
  protocol).
- **No `setsid`.** Not available on macOS.
- **No `date +%s%N`.** Nanosecond epoch formatting is broken on macOS
  `date`; stick to whole-second epoch (`date +%s`) plus pid/sequence
  numbers for uniqueness.
- **`python3` is allowed, but only for JSON one-liners.** The target
  environment's `python3` is 3.8.3 — do not rely on newer stdlib features.
  Do not write substantial logic in Python; it exists only to bridge JSON
  in/out of shell.
- **Run `tests/run-tests.sh` before every commit**, once it exists. A
  failing test suite blocks the commit.
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
